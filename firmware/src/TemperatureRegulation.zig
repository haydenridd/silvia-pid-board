/// Implements a hybrid thermal control scheme for the boiler
/// - When below a certain threshold, acts as a simple on/off thermostat controller
/// - When within a tolerance, functions as a PID controller
const TemperatureRegulation = @This();

const std = @import("std");
const HeaterControl = @import("HeaterControl.zig");
const HeaterIndicator = @import("HeaterIndicator.zig");

state: State = .init,
heater_control: HeaterControl = .{},
heater_indicator: HeaterIndicator = .{},
pid_sampling_deadline_us: u64 = 0,
p_i: f32 = 0.0,
setpoint: f32 = coffee_setpoint,
steam_mode: bool = false,
error_previous: ?f32 = null,

const coffee_setpoint = 108.0;
const steam_setpoint = 145.0;
const control_period_ms = 2000;
const thermostat_delta = 10.0;

pub const State = enum {
    off,
    init,
    thermostat_heating,
    pid,
};

pub fn init(self: *TemperatureRegulation) void {
    self.heater_control.init();
    self.heater_control.immediateOff();
    self.heater_indicator.init();
    self.state = .init;
}

pub fn start(self: *TemperatureRegulation) void {
    self.state = .init;
    self.p_i = 0.0;
    self.error_previous = null;
}

pub fn stop(self: *TemperatureRegulation) void {
    self.state = .off;
    self.heater_control.immediateOff();
}

pub fn steamMode(self: *TemperatureRegulation) void {
    self.steam_mode = true;
    self.setpoint = steam_setpoint;
}

pub fn coffeeMode(self: *TemperatureRegulation) void {
    self.steam_mode = false;
    self.setpoint = coffee_setpoint;
}

fn pidControlLoop(self: *TemperatureRegulation, timestamp_us: u64, current_temperature: f32) void {
    const kp: f32 = if (self.steam_mode) 7.0 else 6.0;
    const ki = 0.3;
    const kd: f32 = if (self.steam_mode) 50.0 else 200.0;
    const max_ki = 15.0;
    const ki_temp_band = 4.0;
    if (timestamp_us >= self.pid_sampling_deadline_us) {
        if (current_temperature < (self.setpoint - thermostat_delta)) {
            self.heater_control.duty_cycle = 100;
            self.state = .thermostat_heating;
            self.error_previous = null;
            self.p_i = 0.0;
            std.log.info("Switching control loop to thermostat mode, setpoint: {d:.1}", .{self.setpoint});
        } else {
            const temp_error = self.setpoint - current_temperature;

            const term_p = kp * temp_error;
            const term_i = v: {
                if ((temp_error <= ki_temp_band) and (temp_error >= -ki_temp_band)) {
                    self.p_i = ki * temp_error + self.p_i;
                    if (self.p_i < -max_ki) {
                        self.p_i = -max_ki;
                    } else if (self.p_i > max_ki) {
                        self.p_i = max_ki;
                    }
                    break :v self.p_i;
                } else {
                    break :v 0.0;
                }
            };
            const term_d: f32 =
                if (self.error_previous) |ep|
                    kd * ((temp_error - ep) / (control_period_ms / 1000))
                else
                    0;

            self.error_previous = temp_error;
            const new_duty = term_p + term_i + term_d;
            if (new_duty < 0) {
                self.heater_control.duty_cycle = 0;
            } else if (new_duty > 100.0) {
                self.heater_control.duty_cycle = 100;
            } else {
                const temp_cycle: u7 = @intFromFloat(new_duty);
                self.heater_control.duty_cycle = (temp_cycle / 5) * 5;
            }
            self.pid_sampling_deadline_us = timestamp_us + 1000 * control_period_ms;
        }
    }
}

pub fn doWork(self: *TemperatureRegulation, timestamp_us: u64, current_temperature: f32) void {
    switch (self.state) {
        .off => {},
        .init => {
            if (current_temperature > (self.setpoint - thermostat_delta)) {
                std.log.info("Starting control loop in PID mode, setpoint: {d:.1}", .{self.setpoint});
                self.heater_control.immediateOff();
                self.state = .pid;
            } else {
                std.log.info("Starting control loop in thermostat mode, setpoint: {d:.1}", .{self.setpoint});
                self.heater_control.duty_cycle = 100;
                self.state = .thermostat_heating;
            }
        },
        .thermostat_heating => {
            if (current_temperature > (self.setpoint - thermostat_delta)) {
                std.log.info("Switching control loop to PID mode, setpoint: {d:.1}", .{self.setpoint});
                self.heater_control.immediateOff();
                self.state = .pid;
            }
        },
        .pid => {
            self.pidControlLoop(timestamp_us, current_temperature);
        },
    }
    self.heater_control.doWork(timestamp_us);
    const at_temp_error = 2.0;
    const heating_zone: HeaterIndicator.HeatingZone = v: {
        if (self.state == .thermostat_heating) {
            break :v .thermostat;
        } else if (self.state == .pid) {
            if (@abs(self.setpoint - current_temperature) < at_temp_error) {
                break :v .pid_at_temp;
            } else {
                break :v .pid_close;
            }
        } else {
            break :v .off;
        }
    };
    self.heater_indicator.doWork(timestamp_us, heating_zone);
}
