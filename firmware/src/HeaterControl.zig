/// Simple state machine for performing long cycle (1 second) PWM on the boiler's heating element
const microzig = @import("microzig");
const rp2040 = microzig.hal;

const HeaterControl = @This();

const State = enum(u1) {
    off = 0,
    on = 1,

    pub fn toggle(self: State) State {
        return @enumFromInt(@intFromEnum(self) ^ 0b1);
    }
};
/// 0->100 duty cycle for heater
duty_cycle: u7 = 0,
state: State = .off,
deadline_us: u64 = 0,

pub const heater_gpio = rp2040.gpio.num(15);
const duty_period_ms = 1000;

pub fn init(_: *HeaterControl) void {
    heater_gpio.set_direction(.out);
    heater_gpio.set_function(.sio);
    heater_gpio.put(0);
}

pub fn immediateOff(self: *HeaterControl) void {
    self.duty_cycle = 0;
    heater_gpio.put(0);
}

pub fn doWork(self: *HeaterControl, timestamp_us: u64) void {
    if (timestamp_us >= self.deadline_us) {
        const on_ms: u32 = (@as(u32, self.duty_cycle) * duty_period_ms) / 100;
        const off_ms: u32 = duty_period_ms - on_ms;

        self.state = self.state.toggle();
        heater_gpio.put(@intFromEnum(self.state));
        if (self.state == .on) {
            self.deadline_us = timestamp_us + on_ms * 1000;
        } else {
            self.deadline_us = timestamp_us + off_ms * 1000;
        }
    }
}
