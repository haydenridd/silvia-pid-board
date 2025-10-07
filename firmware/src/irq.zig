const std = @import("std");
const microzig = @import("microzig");
const peripherals = microzig.chip.peripherals;
const rp2040 = microzig.hal;

pub const critical_section = struct {
    pub inline fn enter() void {
        asm volatile ("cpsid i" ::: .{ .memory = true });
    }

    pub inline fn exit() void {
        asm volatile ("cpsie i" ::: .{ .memory = true });
    }
};

pub fn hardFault() callconv(.c) void {
    std.debug.panic("Hard fault encountered", .{});
}


const GpioIrq =
    struct {
        pub const Edge = enum(u2) { None = 0b00, Falling = 0b01, Rising = 0b10, Both = 0b11 };
        pin: u5,
        edge_type: Edge,
        pub fn enable(self: GpioIrq) void {
            const PROC0_INTEN_ADDR: *volatile u32 = @ptrFromInt(@intFromPtr(&peripherals.IO_BANK0.PROC0_INTE0) + 4 * (self.pin / 8));
            const lsh_amt: u5 = ((self.pin % 8) * 4) + 2;
            const raw_val: u32 = @as(u32, @intFromEnum(self.edge_type)) << lsh_amt;
            const existing: u32 = PROC0_INTEN_ADDR.*;
            PROC0_INTEN_ADDR.* = existing | raw_val;
        }

        pub fn clear(self: GpioIrq) void {
            const INTRN_ADDR: *volatile u32 = @ptrFromInt(@intFromPtr(&peripherals.IO_BANK0.INTR0) + 4 * (self.pin / 8));
            const lsh_amt: u5 = ((self.pin % 8) * 4) + 2;
            const raw_val: u32 = @as(u32, @intFromEnum(self.edge_type)) << lsh_amt;
            INTRN_ADDR.* = raw_val;
        }

        pub inline fn active(self: GpioIrq) bool {
            return edgeActive(self) != Edge.None;
        }

        pub fn edgeActive(self: GpioIrq) Edge {
            const INTSN_ADDR: *volatile u32 = @ptrFromInt(@intFromPtr(&peripherals.IO_BANK0.PROC0_INTS0) + 4 * (self.pin / 8));
            const raw_val: u32 = INTSN_ADDR.*;
            const rsh_amt: u5 = ((self.pin % 8) * 4) + 2;
            const bits: u2 = @intCast((raw_val >> rsh_amt) & 0b11);
            return @enumFromInt(bits);
        }
    };

/// Initializes + enables system IRQs
pub fn init() void {

    // Set input pin to correct mode
    const zero_cross_input_pin = rp2040.gpio.num(2);
    zero_cross_input_pin.set_direction(.in);
    zero_cross_input_pin.set_function(.sio);

    // Enabling pin level IRQs per RP2040 registers
    zero_cross_gpio_irq.clear();
    zero_cross_gpio_irq.enable();

    // Enabling timer IRQ
    zero_cross_timer.set_interrupt_enabled(.alarm0, true);
    
    // Enabling top level ARM NVIC block for desired interrupts
    microzig.interrupt.enable(.IO_IRQ_BANK0);
    microzig.interrupt.enable(.TIMER_IRQ_0);
}

var steam_switch_state: enum {
    waiting_for_edge,
    debouncing_edge,
    check_for_expire,
} = .waiting_for_edge;

var edge_count: u32 = 0;
pub fn gpio() callconv(.c) void {

    // This should be the only GPIO IRQ enabled
    std.debug.assert(zero_cross_gpio_irq.active());
    zero_cross_gpio_irq.clear();
    critical_section.enter();
    const temp_state = steam_switch_state;
    critical_section.exit();

    switch(temp_state) {
        .waiting_for_edge => {
            critical_section.enter();
            steam_switch_state = .debouncing_edge;
            critical_section.exit();
            // Start the timer for 1/60th of a second to see if we're regularly getting falling edges (zero crosses)
            // indicating AC mains is connected and steam switch is on
            zero_cross_timer.schedule_alarm(.alarm0, zero_cross_timer.read_low() +% (1_000_000 / 60));
            
        },
        .debouncing_edge => {
            edge_count += 1;
            // Wait for a full second to keep noise from
            // other switches from triggering the detector
            if(edge_count > 120) {
                edge_count = 0;
                critical_section.enter();
                steam_enabled = true;
                steam_switch_state = .check_for_expire;
                critical_section.exit();
            }
            // Reset alarm
            zero_cross_timer.schedule_alarm(.alarm0, zero_cross_timer.read_low() +% (1_000_000 / 60));
        },
        .check_for_expire => {
            // Reset alarm
            zero_cross_timer.schedule_alarm(.alarm0, zero_cross_timer.read_low() +% (1_000_000 / 60));
        },
    }
    
}

pub fn alarmExpired() callconv(.c) void {
    zero_cross_timer.clear_interrupt(.alarm0);
    critical_section.enter();
    steam_enabled = false;
    steam_switch_state = .waiting_for_edge;
    critical_section.exit();
}

const zero_cross_gpio_irq: GpioIrq = .{ .pin = 2, .edge_type = .Falling };
const zero_cross_timer = rp2040.system_timer.num(0);

/// Safe to read to see if steam should be enabled or not, should not be written
pub var steam_enabled: bool = false;
