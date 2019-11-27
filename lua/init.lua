
-- Put DRV8825 to heavy sleep
gpio.config({gpio=16, dir=gpio.OUT})
gpio.write(16,0)
print("Slept DRV8825")

dofile("main_cayenn_robot_v5.lc")