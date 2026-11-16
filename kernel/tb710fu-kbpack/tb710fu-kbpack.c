// SPDX-License-Identifier: GPL-2.0-only
/*
 * Lenovo Keyboard Pack (TB710FU pogo pins): UART keyboard, touchpad and fold switch.
 * Kernel port of tb710fu-arch-linux's tb710fu-keyboard daemon (protocol: docs/keyboard.md).
 *
 * - serdev on QUP1 SE7 (921600 8N1); host TX goes through a buffer enabled by tx-enable-gpios
 * - plug detect stays gpio-keys' SW_DOCK (gpio81); an input handler follows it, so the switch
 *   keeps working for userspace and nothing fights over the GPIO
 * - pogo VDD: vdd-supply (PM8550 L8B) at 3.296 V, on only while a keyboard is attached, like the
 *   stock lenovo_keyboard.ko (never at boot without a keyboard: regulator-boot-on on L8B reset
 *   the tablet, 2026-11-15)
 * - the input devices exist only while attached, as with the daemon (KWin's tablet mode and
 *   on-screen keyboard look at what is plugged in)
 */
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/input.h>
#include <linux/input/mt.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/random.h>
#include <linux/regulator/consumer.h>
#include <linux/serdev.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/unaligned.h>
#include <linux/workqueue.h>

#include "kbpack-codec.h"

#define KBP_BAUD	921600
#define KBP_VDD_UV	3296000		/* 8 mV grid, not above stock's 3.300 V */
#define KBP_RX_MAX	512
#define TP_X		3199
#define TP_Y		1999
#define TP_SLOTS	4
#define TP_RES		28		/* units/mm, guessed for a ~115x72 mm pad */

/* hid-input.c hid_keyboard[] (HID keyboard usage -> keycode), as in the stock driver */
static const u8 kbp_hid[256] = {
	0x00, 0x00, 0x00, 0x00, 0x1e, 0x30, 0x2e, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26,
	0x32, 0x31, 0x18, 0x19, 0x10, 0x13, 0x1f, 0x14, 0x16, 0x2f, 0x11, 0x2d, 0x15, 0x2c, 0x02, 0x03,
	0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x1c, 0x01, 0x0e, 0x0f, 0x39, 0x0c, 0x0d, 0x1a,
	0x1b, 0x2b, 0x2b, 0x27, 0x28, 0x29, 0x33, 0x34, 0x35, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x40,
	0x41, 0x42, 0x43, 0x44, 0x57, 0x58, 0x63, 0x46, 0x77, 0x6e, 0x66, 0x68, 0x6f, 0x6b, 0x6d, 0x6a,
	0x69, 0x6c, 0x67, 0x45, 0x62, 0x37, 0x4a, 0x4e, 0x60, 0x4f, 0x50, 0x51, 0x4b, 0x4c, 0x4d, 0x47,
	0x48, 0x49, 0x52, 0x53, 0x56, 0x7f, 0x74, 0x75, 0xb7, 0xb8, 0xb9, 0xba, 0xbb, 0xbc, 0xbd, 0xbe,
	0xbf, 0xc0, 0xc1, 0xc2, 0x86, 0x8a, 0x82, 0x84, 0x80, 0x81, 0x83, 0x89, 0x85, 0x87, 0x88, 0x71,
	0x73, 0x72, 0xf0, 0xf0, 0xf0, 0x79, 0xf0, 0x59, 0x5d, 0x7c, 0x5c, 0x5e, 0x5f, 0xf0, 0xf0, 0xf0,
	0x7a, 0x7b, 0x5a, 0x5b, 0x55, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0x6f, 0xf0, 0xf0, 0xf0,
	0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0,
	0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xb3, 0xb4, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0,
	0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0,
	0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0x6f, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0,
	0x1d, 0x2a, 0x38, 0x7d, 0x61, 0x36, 0x64, 0x7e, 0xa4, 0xa6, 0xa5, 0xa3, 0xa1, 0x73, 0x72, 0x71,
	0x96, 0x9e, 0x9f, 0x80, 0x88, 0xb1, 0xb2, 0xb0, 0x8e, 0x98, 0xad, 0x8c, 0xf0, 0xf0, 0xf0, 0xf0,
};

/* modifier byte, bit order: L Ctrl Shift Alt Meta, R Ctrl Shift Alt Meta */
static const u16 kbp_mods[8] = {
	KEY_LEFTCTRL, KEY_LEFTSHIFT, KEY_LEFTALT, KEY_LEFTMETA,
	KEY_RIGHTCTRL, KEY_RIGHTSHIFT, KEY_RIGHTALT, KEY_RIGHTMETA,
};

/* top-row consumer usages; 0x394/0x395 have no Linux meaning (remapped in KDE shortcuts) */
static const struct { u16 usage, code; } kbp_consumer[] = {
	{ 0x0e2, KEY_MUTE }, { 0x0ea, KEY_VOLUMEDOWN }, { 0x0e9, KEY_VOLUMEUP },
	{ 0x070, KEY_BRIGHTNESSDOWN }, { 0x06f, KEY_BRIGHTNESSUP }, { 0x391, KEY_MICMUTE },
	{ 0x394, KEY_FULL_SCREEN }, { 0x395, KEY_PROG2 }, { 0x398, KEY_ASSISTANT },
};

enum { KBP_SEND_HELLO, KBP_SEND_CAPS, KBP_CAPS_ON };

struct kbpack {
	struct serdev_device *serdev;
	struct regulator *vdd;
	struct gpio_desc *tx_en;
	struct input_handler dock_handler;
	struct work_struct work;
	struct mutex lock;		/* attach/detach and sends (work) */
	unsigned long flags;
	bool want_docked;		/* last SW_DOCK value */
	bool docked;			/* VDD on, input devices registered */
	bool vdd_on;

	spinlock_t in_lock;		/* receive path vs. detach */
	bool live;
	struct input_dev *kbd, *tp, *sw;
	u8 prev[8];			/* last keyboard report: modifiers, reserved, 6 usages */
	u16 cons;			/* consumer key held */

	u8 rx[KBP_RX_MAX];
	u8 plain[KBP_RX_MAX];
	int rx_len;			/* > KBP_RX_MAX: overflowed, skip to the next 7E */
};

/* ---------------------------------------------------------------- reports */

static bool kbp_has(const u8 *u, u8 x)
{
	return memchr(u, x, 6) != NULL;
}

static void kbp_keyboard(struct kbpack *kb, const u8 *p)
{
	const u8 *old = kb->prev + 2, *now = p + 4;
	bool changed = false;
	int i;

	/* releases first, modifiers last; presses: modifiers first */
	for (i = 0; i < 6; i++)
		if (old[i] && !kbp_has(now, old[i]) && kbp_hid[old[i]] && kbp_hid[old[i]] != 0xf0) {
			input_report_key(kb->kbd, kbp_hid[old[i]], 0);
			changed = true;
		}
	for (i = 0; i < 8; i++)
		if ((kb->prev[0] & ~p[2]) & BIT(i)) {
			input_report_key(kb->kbd, kbp_mods[i], 0);
			changed = true;
		}
	for (i = 0; i < 8; i++)
		if ((p[2] & ~kb->prev[0]) & BIT(i)) {
			input_report_key(kb->kbd, kbp_mods[i], 1);
			changed = true;
		}
	for (i = 0; i < 6; i++)
		if (now[i] && !kbp_has(old, now[i]) && kbp_hid[now[i]] && kbp_hid[now[i]] != 0xf0) {
			input_report_key(kb->kbd, kbp_hid[now[i]], 1);
			changed = true;
		}
	if (changed)
		input_sync(kb->kbd);
	kb->prev[0] = p[2];
	memcpy(kb->prev + 2, now, 6);
}

static void kbp_consumer_key(struct kbpack *kb, u16 usage)
{
	u16 code = 0;
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(kbp_consumer); i++)
		if (kbp_consumer[i].usage == usage)
			code = kbp_consumer[i].code;
	if (usage && !code)
		dev_dbg(&kb->serdev->dev, "unmapped consumer usage %#x\n", usage);
	if (code == kb->cons)
		return;
	if (kb->cons)
		input_report_key(kb->kbd, kb->cons, 0);
	if (code)
		input_report_key(kb->kbd, code, 1);
	input_sync(kb->kbd);
	kb->cons = code;
}

/* 13 len btn {f x:le16 y:le16}...: f >> 4 = slot, bit0 = touching (7) / lifting (6) */
static void kbp_touch(struct kbpack *kb, const u8 *p, int n)
{
	int i, cnt = (min_t(int, p[1], n - 2) - 1) / 5;

	for (i = 0; i < cnt; i++) {
		const u8 *e = p + 3 + 5 * i;
		int slot = e[0] >> 4;

		if (slot >= TP_SLOTS || !(e[0] & 1))
			continue;	/* lifted or unknown: dropped by input_mt_sync_frame */
		input_mt_slot(kb->tp, slot);
		input_mt_report_slot_state(kb->tp, MT_TOOL_FINGER, true);
		input_report_abs(kb->tp, ABS_MT_POSITION_X, get_unaligned_le16(e + 1));
		input_report_abs(kb->tp, ABS_MT_POSITION_Y, get_unaligned_le16(e + 3));
	}
	input_mt_sync_frame(kb->tp);
	input_report_key(kb->tp, BTN_LEFT, p[2] & 1);
	input_sync(kb->tp);
}

static void kbp_packet(struct kbpack *kb, const u8 *p, int n)
{
	if (n < 2)
		return;
	switch (p[0]) {
	case 0x11:
		if (n >= 10)
			kbp_keyboard(kb, p);
		break;
	case 0x12:
		if (n >= 4)
			kbp_consumer_key(kb, p[2] | p[3] << 8);
		break;
	case 0x13:
		if (n >= 3)
			kbp_touch(kb, p, n);
		break;
	case 0x15:		/* 15 03 02 01 vv: keys enabled; vv = 0 folded back */
		if (n >= 5) {
			input_report_switch(kb->sw, SW_TABLET_MODE, p[4] == 0);
			input_sync(kb->sw);
		}
		break;
	case 0x16:		/* plug-in hello: answer like stock (touchpad autosleep off) */
		if (p[1] == 3) {
			set_bit(KBP_SEND_HELLO, &kb->flags);
			schedule_work(&kb->work);
		}
		break;
	}
}

static size_t kbp_receive(struct serdev_device *serdev, const u8 *buf, size_t count)
{
	struct kbpack *kb = serdev_device_get_drvdata(serdev);
	unsigned long irqf;
	size_t i;
	int n;

	for (i = 0; i < count; i++) {
		if (buf[i] != 0x7e) {
			if (kb->rx_len < KBP_RX_MAX)
				kb->rx[kb->rx_len] = buf[i];
			if (kb->rx_len <= KBP_RX_MAX)
				kb->rx_len++;
			continue;
		}
		n = kb->rx_len <= KBP_RX_MAX ? kbp_unframe(kb->rx, kb->rx_len, kb->plain) : -1;
		kb->rx_len = 0;
		if (n <= 0)
			continue;
		spin_lock_irqsave(&kb->in_lock, irqf);
		if (kb->live)
			kbp_packet(kb, kb->plain, n);
		spin_unlock_irqrestore(&kb->in_lock, irqf);
	}
	return count;
}

static const struct serdev_device_ops kbp_serdev_ops = {
	.receive_buf = kbp_receive,
	.write_wakeup = serdev_device_write_wakeup,
};

/* ---------------------------------------------------------------- host -> keyboard */

static void kbp_send(struct kbpack *kb, const u8 *plain, int n)
{
	u8 f[2 * 16 + 8];
	int len = kbp_frame(plain, n, get_random_u8() & 0x7f, f);

	gpiod_set_value_cansleep(kb->tx_en, 1);
	serdev_device_write_buf(kb->serdev, f, len);
	serdev_device_wait_until_sent(kb->serdev, msecs_to_jiffies(50));
	gpiod_set_value_cansleep(kb->tx_en, 0);
}

/* Caps Lock LED, written back by the compositor (atomic context: defer to the work) */
static int kbp_kbd_event(struct input_dev *dev, unsigned int type, unsigned int code, int value)
{
	struct kbpack *kb = input_get_drvdata(dev);

	if (type != EV_LED || code != LED_CAPSL)
		return -1;
	assign_bit(KBP_CAPS_ON, &kb->flags, value);
	set_bit(KBP_SEND_CAPS, &kb->flags);
	schedule_work(&kb->work);
	return 0;
}

/* ---------------------------------------------------------------- attach / detach */

static struct input_dev *kbp_input(struct kbpack *kb, const char *name)
{
	struct input_dev *in = input_allocate_device();

	if (!in)
		return NULL;
	in->name = name;
	in->phys = "tb710fu-kbpack/input0";
	in->id.bustype = BUS_HOST;
	in->id.vendor = 0x17ef;
	in->id.product = 0x6271;
	in->dev.parent = &kb->serdev->dev;
	input_set_drvdata(in, kb);
	return in;
}

static int kbp_inputs(struct kbpack *kb)
{
	struct input_dev *kbd, *tp, *sw;
	int i, err = -ENOMEM;

	kbd = kbp_input(kb, "Lenovo Keyboard Pack Keyboard");
	tp = kbp_input(kb, "Lenovo Keyboard Pack Touchpad");
	sw = kbp_input(kb, "Lenovo Keyboard Pack Tablet Mode");
	if (!kbd || !tp || !sw)
		goto free;

	/* no EV_REP: the compositor repeats keys itself, as with the daemon's uinput device */
	for (i = 0; i < 256; i++)
		if (kbp_hid[i] && kbp_hid[i] != 0xf0)
			input_set_capability(kbd, EV_KEY, kbp_hid[i]);
	for (i = 0; i < 8; i++)
		input_set_capability(kbd, EV_KEY, kbp_mods[i]);
	for (i = 0; i < ARRAY_SIZE(kbp_consumer); i++)
		input_set_capability(kbd, EV_KEY, kbp_consumer[i].code);
	input_set_capability(kbd, EV_LED, LED_CAPSL);
	kbd->event = kbp_kbd_event;

	input_set_capability(tp, EV_KEY, BTN_LEFT);
	input_set_abs_params(tp, ABS_MT_POSITION_X, 0, TP_X, 0, 0);
	input_set_abs_params(tp, ABS_MT_POSITION_Y, 0, TP_Y, 0, 0);
	input_abs_set_res(tp, ABS_MT_POSITION_X, TP_RES);
	input_abs_set_res(tp, ABS_MT_POSITION_Y, TP_RES);
	__set_bit(INPUT_PROP_BUTTONPAD, tp->propbit);
	/* POINTER: BTN_TOUCH, BTN_TOOL_*, ABS_X/Y emulation; DROP_UNUSED: slots not in a packet lift */
	err = input_mt_init_slots(tp, TP_SLOTS, INPUT_MT_POINTER | INPUT_MT_DROP_UNUSED);
	if (err)
		goto free;

	input_set_capability(sw, EV_SW, SW_TABLET_MODE);

	err = input_register_device(kbd);
	if (err)
		goto free;
	err = input_register_device(tp);
	if (err) {
		input_unregister_device(kbd);
		kbd = NULL;
		goto free;
	}
	err = input_register_device(sw);
	if (err) {
		input_unregister_device(kbd);
		input_unregister_device(tp);
		kbd = tp = NULL;
		goto free;
	}
	kb->kbd = kbd;
	kb->tp = tp;
	kb->sw = sw;
	return 0;
free:
	input_free_device(kbd);
	input_free_device(tp);
	input_free_device(sw);
	return err;
}

static void kbp_attach(struct kbpack *kb)
{
	struct device *dev = &kb->serdev->dev;
	unsigned long irqf;
	int err;

	if (!kb->vdd_on) {
		err = regulator_set_voltage(kb->vdd, KBP_VDD_UV, KBP_VDD_UV);
		if (!err)
			err = regulator_enable(kb->vdd);
		if (err) {
			dev_err(dev, "keyboard VDD: %d\n", err);
			return;
		}
		kb->vdd_on = true;
	}
	err = kbp_inputs(kb);
	if (err) {
		dev_err(dev, "input devices: %d\n", err);
		return;
	}
	memset(kb->prev, 0, sizeof(kb->prev));
	kb->cons = 0;
	spin_lock_irqsave(&kb->in_lock, irqf);
	kb->live = true;
	spin_unlock_irqrestore(&kb->in_lock, irqf);
	kb->docked = true;
	dev_info(dev, "keyboard attached\n");
}

static void kbp_detach(struct kbpack *kb)
{
	unsigned long irqf;

	spin_lock_irqsave(&kb->in_lock, irqf);
	kb->live = false;
	spin_unlock_irqrestore(&kb->in_lock, irqf);
	if (kb->kbd) {
		/* unregistering releases held keys and lifts fingers */
		input_unregister_device(kb->kbd);
		input_unregister_device(kb->tp);
		input_unregister_device(kb->sw);
		kb->kbd = kb->tp = kb->sw = NULL;
	}
	if (kb->vdd_on && !regulator_disable(kb->vdd))
		kb->vdd_on = false;
	kb->docked = false;
	dev_info(&kb->serdev->dev, "keyboard detached\n");
}

static void kbp_work(struct work_struct *work)
{
	static const u8 hello[] = { 0x6a, 0x04, 0x33, 0x02, 0x00, 0x00 };
	struct kbpack *kb = container_of(work, struct kbpack, work);

	mutex_lock(&kb->lock);
	if (READ_ONCE(kb->want_docked) != kb->docked) {
		if (kb->docked)
			kbp_detach(kb);
		else
			kbp_attach(kb);
	}
	if (kb->docked && test_and_clear_bit(KBP_SEND_HELLO, &kb->flags))
		kbp_send(kb, hello, sizeof(hello));
	if (kb->docked && test_and_clear_bit(KBP_SEND_CAPS, &kb->flags)) {
		u8 led[] = { 0x6a, 0x03, 0x27, 0x01, test_bit(KBP_CAPS_ON, &kb->flags) };

		kbp_send(kb, led, sizeof(led));
	}
	mutex_unlock(&kb->lock);
}

/* ---------------------------------------------------------------- SW_DOCK (gpio-keys) */

static void kbp_dock_event(struct input_handle *handle, unsigned int type, unsigned int code,
			   int value)
{
	struct kbpack *kb = container_of(handle->handler, struct kbpack, dock_handler);

	if (type == EV_SW && code == SW_DOCK) {
		WRITE_ONCE(kb->want_docked, !!value);
		schedule_work(&kb->work);
	}
}

static int kbp_dock_connect(struct input_handler *handler, struct input_dev *dev,
			    const struct input_device_id *id)
{
	struct kbpack *kb = container_of(handler, struct kbpack, dock_handler);
	struct input_handle *handle;
	int err;

	handle = kzalloc(sizeof(*handle), GFP_KERNEL);
	if (!handle)
		return -ENOMEM;
	handle->dev = dev;
	handle->handler = handler;
	handle->name = "tb710fu-kbpack";
	err = input_register_handle(handle);
	if (err)
		goto free;
	err = input_open_device(handle);
	if (err)
		goto unregister;
	WRITE_ONCE(kb->want_docked, test_bit(SW_DOCK, dev->sw));
	schedule_work(&kb->work);
	return 0;
unregister:
	input_unregister_handle(handle);
free:
	kfree(handle);
	return err;
}

static void kbp_dock_disconnect(struct input_handle *handle)
{
	input_close_device(handle);
	input_unregister_handle(handle);
	kfree(handle);
}

static const struct input_device_id kbp_dock_ids[] = {
	{
		.flags = INPUT_DEVICE_ID_MATCH_EVBIT | INPUT_DEVICE_ID_MATCH_SWBIT,
		.evbit = { BIT_MASK(EV_SW) },
		.swbit = { [BIT_WORD(SW_DOCK)] = BIT_MASK(SW_DOCK) },
	},
	{ }
};

/* ---------------------------------------------------------------- probe */

static int kbp_probe(struct serdev_device *serdev)
{
	struct device *dev = &serdev->dev;
	struct kbpack *kb;
	int err;

	kb = devm_kzalloc(dev, sizeof(*kb), GFP_KERNEL);
	if (!kb)
		return -ENOMEM;
	kb->serdev = serdev;
	mutex_init(&kb->lock);
	spin_lock_init(&kb->in_lock);
	INIT_WORK(&kb->work, kbp_work);
	serdev_device_set_drvdata(serdev, kb);

	kb->vdd = devm_regulator_get(dev, "vdd");
	if (IS_ERR(kb->vdd))
		return dev_err_probe(dev, PTR_ERR(kb->vdd), "vdd-supply\n");
	kb->tx_en = devm_gpiod_get(dev, "tx-enable", GPIOD_OUT_LOW);
	if (IS_ERR(kb->tx_en))
		return dev_err_probe(dev, PTR_ERR(kb->tx_en), "tx-enable-gpios\n");

	serdev_device_set_client_ops(serdev, &kbp_serdev_ops);
	err = devm_serdev_device_open(dev, serdev);
	if (err)
		return dev_err_probe(dev, err, "open UART\n");
	serdev_device_set_baudrate(serdev, KBP_BAUD);
	serdev_device_set_flow_control(serdev, false);
	err = serdev_device_set_parity(serdev, SERDEV_PARITY_NONE);
	if (err)
		return dev_err_probe(dev, err, "parity\n");

	kb->dock_handler.name = "tb710fu-kbpack";
	kb->dock_handler.event = kbp_dock_event;
	kb->dock_handler.connect = kbp_dock_connect;
	kb->dock_handler.disconnect = kbp_dock_disconnect;
	kb->dock_handler.id_table = kbp_dock_ids;
	err = input_register_handler(&kb->dock_handler);	/* connects to gpio-keys: initial state */
	if (err)
		return dev_err_probe(dev, err, "SW_DOCK handler\n");
	return 0;
}

static void kbp_remove(struct serdev_device *serdev)
{
	struct kbpack *kb = serdev_device_get_drvdata(serdev);

	input_unregister_handler(&kb->dock_handler);
	mutex_lock(&kb->lock);
	if (kb->docked)
		kbp_detach(kb);	/* not live: the receive path schedules nothing after this */
	mutex_unlock(&kb->lock);
	cancel_work_sync(&kb->work);
}

static const struct of_device_id kbp_of_match[] = {
	{ .compatible = "lenovo,tb710fu-keyboard-pack" },
	{ }
};
MODULE_DEVICE_TABLE(of, kbp_of_match);

static struct serdev_device_driver kbp_driver = {
	.probe = kbp_probe,
	.remove = kbp_remove,
	.driver = {
		.name = "tb710fu-kbpack",
		.of_match_table = kbp_of_match,
	},
};
module_serdev_device_driver(kbp_driver);

MODULE_DESCRIPTION("Lenovo Keyboard Pack (TB710FU pogo UART)");
MODULE_LICENSE("GPL");
