You need to install the NodeMCU-touch-pulsecnt-rmttx.bin firmware to your ESP32. To do this you must use esptool. This can be installed from Espressif's distribution online located at https://github.com/espressif/esptool

Or, you can also try to use the distributed .exe in this repo. However, it may only work after you've installed Python and did the "pip install esptool" command like in Espressif's documenation.

The three .bin files you need are in this folder. The command you will have to run will be something like:

esptool.py.exe --port COM7 write_flash 0x1000 bootloader.bin 0x10000 NodeMCU-touch-pulsecnt-rmttx.bin 0x8000 partitions.bin

or
esptool.py --port COM7 write_flash 0x1000 bootloader.bin 0x10000 NodeMCU-touch-pulsecnt-rmttx.bin 0x8000 partitions.bin

Change your serial port to the appropriate port your ESP32 is connected to.
