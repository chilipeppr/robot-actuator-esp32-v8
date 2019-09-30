echo on
esptool.py.exe --port COM7 write_flash 0x1000 bootloader.bin 0x10000 NodeMCU-touch-pulsecnt-rmttx.bin 0x8000 partitions.bin
