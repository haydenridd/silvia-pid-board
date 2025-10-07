# PID Control Firmware

The following describes the firmware running on the Rpi Pico that implements PID control for the heater.

## Zig

The firmware is written in the [Zig](https://ziglang.org/) programming language, and currently tracks version `0.15.1`.
It uses the [MicroZig project](https://microzig.tech/) to provide a HAL and build utilities for the RP2040, a project
which I also contribute to!

## Building + Flashing

Installing Zig is required to build firmware. Once installed, build firmware by running `zig build` in this directory.
You will see two artifacts in `zig-out`. The `.elf` file can be flashed to the Pico over the SWD interface using a
debugger. There is an [example script](scripts/flash_fw.sh) that shows how this is accomplished with a JLink. The `.uf2`
file can be transferred to the Pico connected to a computer when it's in mass storage mode.

By default, the build occurs in debug mode. To build at higher optimization levels see `zig build -h`. 

## Architecture

The code follows a "super loop" architecture, with code seperated into modules that are given cpu time with the naming convention
`doWork()` as a method. Technically, this is known as "co-operative multitasking with static priority", where each module can't
get CPU cycles until the previous module yields control. The order in the loop each module is called can be thought
of as the "priority".

Examine the code for more details, but the high level modules are briefly described below.

### `Blink`

Blinks the on-board LED of the Pico at a fixed interval, as a sanity check that firmware hasn't crashed.

### `DataLogger`

Outputs CSV data points to a UART port for logging.

### `TemperatureRegulation`

Performs the PID control loop given regular temperature measurements from the RTD sensor.

### `RtdMeasurement`

Handles fetching temperature readings from the MAX31865 chip.

### `Cli`

Implements a rudimentary CLI for controlling firmware as it runs. Currently uses [RTT](https://kb.segger.com/RTT), however it is
designed in a way to take a generic `std.Io.Reader` as its input
source. A fun example of `comptime` usage to cut down on code repetition.

### `HeaterIndicator`

Controls the heater indicator LED using PWM. Currently it only has three states:
- Solid on: temperature is far enough away from target such that the boiler is turned on 100%
- Pulsing on: temperature is within a threshold to where PID is bringing temperature closer to target
- Solid off: Temperature is within 2C of target

Note that "solid on" still isn't at 100% duty cycle. I experimentally determined a nice value that seemed to match the brightness of the other lamps on the machine.


### `irq`

A special module that isn't "given work" like other modules, because
it entirely executes in interrupt handlers. Interrupts are used to
handle detecting regular zero crossing events on the pin that senses
whether or not the steam switch is turned on.