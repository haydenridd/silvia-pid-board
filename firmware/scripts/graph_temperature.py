import serial
import bokeh
from bokeh.models import LinearAxis, Range1d, Legend, ColumnDataSource
from bokeh.io import curdoc
from bokeh.plotting import figure
import time
import datetime


ser = serial.Serial("/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_AB0MN1QY-if00-port0", 115200, timeout=1)

temp_ds = ColumnDataSource(data = {"Temperature": [], "Time": []})
dc_ds = ColumnDataSource(data = {"Duty Cycle": [], "Time": []})
setpoint_ds = ColumnDataSource(data = {"Set Point": [], "Time": []})
init_ts = datetime.datetime.now().timestamp()

def callback():
    global temp_ds
    global dc_ds
    global init_ts
    global ser
    try:
        ln = ser.readline().decode("utf-8")
        ls = ln.strip().split(",")
        time_val = datetime.datetime.now().timestamp() - init_ts
        temp_ds.stream({"Temperature": [float(ls[0])], "Time": [time_val]})
        dc_ds.stream({"Duty Cycle": [float(ls[1])], "Time": [time_val]})
        setpoint_ds.stream({"Set Point": [float(ls[2])], "Time": [time_val]})
    except Exception as e:
        print("Error reading data point: ", e)
        pass


p = figure(title="Temperature vs. Time", x_axis_label="Time", y_axis_label="Temperature (C)")
p.line(x="Time", y="Temperature", line_width=2, source=temp_ds, color="red")
p.line(x="Time", y="Set Point", line_width=2, source=setpoint_ds, color="black")
p.y_range = Range1d(80, 160)
p.extra_y_ranges["duty_range"] = Range1d(0, 102)
ax2 = LinearAxis(y_range_name="duty_range", axis_label="Duty Cycle")
p.add_layout(ax2, "right")
p.line(x="Time", y="Duty Cycle", line_width=2, source=dc_ds, color="blue", y_range_name="duty_range")

curdoc().add_periodic_callback(callback, 100)
curdoc().add_root(p)

