// SPDX-License-Identifier: GPL-2.0-only
/*
 * EETI eGalax serial touchscreen driver (UT protocol variant)
 *
 * Handles eGalax serial touchscreen controllers that use the 10-byte
 * UT-prefixed binary protocol, commonly found in POS terminals from
 * FlyTech, Touch Dynamic, and others.
 *
 * The mainline egalax_ts_serial driver handles 5/6-byte packets with
 * bit-7 start framing. This driver handles the 10-byte UT (0x55 0x54)
 * protocol variant which is incompatible with the mainline driver.
 *
 * Protocol:
 *   Byte 0:   0x55 ('U') - sync
 *   Byte 1:   0x54 ('T') - sync
 *   Byte 2:   Status (0x01=down, 0x02=move, 0x04=up, high nibble varies)
 *   Byte 3:   X low byte
 *   Byte 4:   X high byte
 *   Byte 5:   Y low byte
 *   Byte 6:   Y high byte
 *   Byte 7:   Z/pressure low byte
 *   Byte 8:   Z/pressure high byte
 *   Byte 9:   Checksum
 *
 * Tested on: FlyTech P495-C48 (POS 495), ICH8M UART, ttyS4
 *
 * Copyright (c) 2026
 * Based on egalax_ts_serial.c by Zoltán Böszörményi
 */

#include <linux/errno.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/input.h>
#include <linux/serio.h>

#define DRIVER_DESC	"EETI eGalax serial touchscreen driver (UT protocol)"

#define EGALAX_UT_PKT_LEN	10
#define EGALAX_UT_SYNC_0	0x55
#define EGALAX_UT_SYNC_1	0x54

/* Status byte: low nibble carries touch state */
#define EGALAX_UT_TOUCH_DOWN	0x01
#define EGALAX_UT_TOUCH_MOVE	0x02
#define EGALAX_UT_TOUCH_UP	0x04

#define EGALAX_UT_MIN_XC	0
#define EGALAX_UT_MAX_XC	0x4000
#define EGALAX_UT_MIN_YC	0
#define EGALAX_UT_MAX_YC	0x4000

/*
 * Sync state machine states
 */
enum egalax_ut_state {
	EGALAX_UT_WAIT_SYNC_0,
	EGALAX_UT_WAIT_SYNC_1,
	EGALAX_UT_COLLECTING,
};

struct egalax_ut {
	struct input_dev *input;
	struct serio *serio;
	enum egalax_ut_state state;
	int idx;
	u8 data[EGALAX_UT_PKT_LEN];
	char phys[32];
};

static void egalax_ut_process_data(struct egalax_ut *egalax)
{
	struct input_dev *dev = egalax->input;
	u8 *data = egalax->data;
	u8 status;
	u16 x, y;
	bool touch;

	status = data[2] & 0x07; /* low 3 bits = touch state */
	x = (u16)data[3] | ((u16)data[4] << 8);
	y = (u16)data[5] | ((u16)data[6] << 8);

	touch = (status & EGALAX_UT_TOUCH_DOWN) ||
		(status & EGALAX_UT_TOUCH_MOVE);

	input_report_key(dev, BTN_TOUCH, touch ? 1 : 0);
	input_report_abs(dev, ABS_X, x);
	input_report_abs(dev, ABS_Y, y);
	input_sync(dev);
}

static irqreturn_t egalax_ut_interrupt(struct serio *serio,
				       unsigned char data, unsigned int flags)
{
	struct egalax_ut *egalax = serio_get_drvdata(serio);

	switch (egalax->state) {
	case EGALAX_UT_WAIT_SYNC_0:
		if (data == EGALAX_UT_SYNC_0) {
			egalax->data[0] = data;
			egalax->idx = 1;
			egalax->state = EGALAX_UT_WAIT_SYNC_1;
		}
		break;

	case EGALAX_UT_WAIT_SYNC_1:
		if (data == EGALAX_UT_SYNC_1) {
			egalax->data[1] = data;
			egalax->idx = 2;
			egalax->state = EGALAX_UT_COLLECTING;
		} else if (data == EGALAX_UT_SYNC_0) {
			/* Could be start of new packet, stay in WAIT_SYNC_1 */
			egalax->data[0] = data;
			egalax->idx = 1;
		} else {
			/* Not a valid sync, reset */
			egalax->state = EGALAX_UT_WAIT_SYNC_0;
			egalax->idx = 0;
		}
		break;

	case EGALAX_UT_COLLECTING:
		egalax->data[egalax->idx++] = data;
		if (egalax->idx == EGALAX_UT_PKT_LEN) {
			egalax_ut_process_data(egalax);
			egalax->state = EGALAX_UT_WAIT_SYNC_0;
			egalax->idx = 0;
		}
		break;
	}

	return IRQ_HANDLED;
}

static int egalax_ut_connect(struct serio *serio, struct serio_driver *drv)
{
	struct egalax_ut *egalax;
	struct input_dev *input_dev;
	int error;

	egalax = kzalloc(sizeof(*egalax), GFP_KERNEL);
	input_dev = input_allocate_device();
	if (!egalax || !input_dev) {
		error = -ENOMEM;
		goto err_free_mem;
	}

	egalax->serio = serio;
	egalax->input = input_dev;
	egalax->state = EGALAX_UT_WAIT_SYNC_0;
	egalax->idx = 0;
	scnprintf(egalax->phys, sizeof(egalax->phys),
		  "%s/input0", serio->phys);

	input_dev->name = "EETI eGalaxTouch Serial TouchScreen (UT)";
	input_dev->phys = egalax->phys;
	input_dev->id.bustype = BUS_RS232;
	input_dev->id.vendor = SERIO_EGALAX;
	input_dev->id.product = 0x0001;
	input_dev->id.version = 0x0002;
	input_dev->dev.parent = &serio->dev;

	input_set_capability(input_dev, EV_KEY, BTN_TOUCH);
	input_set_abs_params(input_dev, ABS_X,
			     EGALAX_UT_MIN_XC, EGALAX_UT_MAX_XC, 0, 0);
	input_set_abs_params(input_dev, ABS_Y,
			     EGALAX_UT_MIN_YC, EGALAX_UT_MAX_YC, 0, 0);

	serio_set_drvdata(serio, egalax);

	error = serio_open(serio, drv);
	if (error)
		goto err_reset_drvdata;

	error = input_register_device(input_dev);
	if (error)
		goto err_close_serio;

	return 0;

err_close_serio:
	serio_close(serio);
err_reset_drvdata:
	serio_set_drvdata(serio, NULL);
err_free_mem:
	input_free_device(input_dev);
	kfree(egalax);
	return error;
}

static void egalax_ut_disconnect(struct serio *serio)
{
	struct egalax_ut *egalax = serio_get_drvdata(serio);

	serio_close(serio);
	serio_set_drvdata(serio, NULL);
	input_unregister_device(egalax->input);
	kfree(egalax);
}

static const struct serio_device_id egalax_ut_serio_ids[] = {
	{
		.type	= SERIO_RS232,
		.proto	= SERIO_EGALAX,
		.id	= SERIO_ANY,
		.extra	= SERIO_ANY,
	},
	{ 0 }
};

MODULE_DEVICE_TABLE(serio, egalax_ut_serio_ids);

static struct serio_driver egalax_ut_drv = {
	.driver		= {
		.name	= "egalax_ut",
	},
	.description	= DRIVER_DESC,
	.id_table	= egalax_ut_serio_ids,
	.interrupt	= egalax_ut_interrupt,
	.connect	= egalax_ut_connect,
	.disconnect	= egalax_ut_disconnect,
};
module_serio_driver(egalax_ut_drv);

MODULE_AUTHOR("Bailey <bacedia>");
MODULE_DESCRIPTION(DRIVER_DESC);
MODULE_LICENSE("GPL v2");
