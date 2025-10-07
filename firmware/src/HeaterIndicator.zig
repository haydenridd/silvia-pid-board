/// Controls the "heating" indicator LED based on what mode the heating control loop is currently in
const std = @import("std");
const HeaterIndicator = @This();
const rp2040 = @import("microzig").hal;
const Pwm = rp2040.pwm.Pwm;

pub const HeatingZone = enum {
    off,
    thermostat,
    pid_close,
    pid_at_temp,
};

state: enum {
    off,
    pulsing,
    solid,
} = .off,
pwm_increment_deadline_us: u64 = 0,
pwm_level: u16 = 0,

const silvia_led_gpio = rp2040.gpio.num(3);
const led_pwm: Pwm = .{ .slice_number = 1, .channel = .b };
const pwm_increment_period_us = 20_000;
const max_brightness_pwm_level = 100;
pub fn init(_: HeaterIndicator) void {
    silvia_led_gpio.set_direction(.out);
    silvia_led_gpio.set_function(.pwm);
    // Experimentally found to produce a nice "max brightness" at level 100 that matches existing lamps
    led_pwm.slice().set_wrap(12288);
    led_pwm.set_level(max_brightness_pwm_level);
    led_pwm.slice().enable();
}

pub fn doWork(self: *HeaterIndicator, timestamp_us: u64, heating_zone: HeatingZone) void {
    self.state = switch (heating_zone) {
        .off => .off,
        .thermostat => .solid,
        .pid_close => .pulsing,
        .pid_at_temp => .off,
    };
    switch (self.state) {
        .off => {
            led_pwm.set_level(0);
            self.pwm_level = 0;
        },
        .pulsing => {
            if (timestamp_us >= self.pwm_increment_deadline_us) {
                self.pwm_level += 5;
                self.pwm_level %= 200;
                if (self.pwm_level > 100) {
                    led_pwm.set_level(100 - (self.pwm_level - 100));
                } else {
                    led_pwm.set_level(self.pwm_level);
                }
                self.pwm_increment_deadline_us = timestamp_us + pwm_increment_period_us;
            }
        },
        .solid => {
            led_pwm.set_level(max_brightness_pwm_level);
            self.pwm_level = max_brightness_pwm_level;
        },
    }
}
