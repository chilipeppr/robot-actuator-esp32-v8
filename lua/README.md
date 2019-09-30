You can upload this Lua code via the ChiliPeppr workspace for ESP32 located at:
http://chilipeppr.com/esp32

To use this workspace you need to download and run Serial Port JSON Server. You can do this from the widget in the upper right corner which has links to the releases for Windows, Mac, Linux, and Raspberry Pi. Then connect to SPJS from your workspace via connecting to localhost or the IP address of the machine running SPJS. 

Once you've connected to SPJS, it will show you a list of serial ports. Connect to your ESP32. Now load all of the files into the editor and click "Upload All" to get the code on the Flash memory of your ESP32. This will take a bit to upload them, but you'll here a ding sound when they are done.

Here is a screenshot of what your workspace should look similar to.
![alt text](chilipeppr.png "")

Then you can restart your ESP32 and it should run init.lua to launch all of the code so you can use your actuator.