-- Put DRV8825 to heavy sleep
gpio.config({gpio=16, dir=gpio.OUT})
gpio.write(16,0)
print("Slept DRV8825")

-- Runs the main file
dofile("main.lc")
