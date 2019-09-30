/* 
GPIO Matrix allows you to redirect all signals inside of the ESP32 to any/all GPIO.
Authored by: ChiliPeppr (John Lauer) 2019

ESP32 has roughly 40 GPIOs, but it also has about 100 peripheral signals from 
sub-systems such as RMT, LEDC, MCPWM, I2S, CAN, etc. Together this 
is over 150 signals. You can re-route and connect any of these signals to each other via 
the GPIO matrix including one-to-many and many-to-one.

This code is in the Public Domain (or CC0 licensed, at your option.)
Make modifications at will and freely.

Unless required by applicable law or agreed to in writing, this
software is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied.
*/

#include "module.h"
#include "lauxlib.h"
#include "lmem.h"

#include "driver/gpio.h"
#include "soc/gpio_sig_map.h"

#include <assert.h>

// Lua: gpiomatrix.periphOutToGpioIn(periph, gpio)
// Example:
//   -- Map LEDC peripheral output to GPIO that Pulse Counter listens on 
//   gpiomatrix.periphOutToGpioIn(
//     gpiomatrix.LEDC_HS_SIG_OUT0_IDX, -- Peripheral
//     gm.pinPulseCnt  -- GPIO
//   )
static int gpiomatrix_periphOutToGpioIn( lua_State *L ) {

  int periph = luaL_checkint (L, 1);
  int gpio = luaL_checkint (L, 2);

  // In this example below, pin_number is the GPIO pin number. io_signal_in and io_signal_out are values 
  // identifying the peripheral and signal you want to route: signal numbers can be found in 
  // esp-idf/components/soc/esp32/include/soc/gpio_sig_map.h . Use *_IN_IDX as possible values 
  // for io_signal_in, *_OUT_IDX for io_signal_out.

  // Connect the pin to the GPIO matrix.
  // PIN_FUNC_SELECT(GPIO_PIN_MUX_REG[pin_number], PIN_FUNC_GPIO);

  // Set the direction. GPIO_MODE_INPUT always makes it an input, GPIO_MODE_OUTPUT always makes it 
  // an output, GPIO_MODE_INPUT_OUTPUT lets the peripheral decide what direction it has. You usually 
  // want the last one.
  // gpio_set_direction(gpio, GPIO_MODE_INPUT_OUTPUT);

  // Connect the output functionality of a peripheral to the pin you want. This allows a peripheral 
  // to set the direction of the pin (in case it's configured as GPIO_INPUT_OUTPUT) and set the 
  // output value. *_OUT_IDX
  gpio_matrix_out(gpio, periph, false, false);

  // Connect the input functionality of a peripheral to the pin. This allows the peripheral to 
  // read the signal indicated from this pin. *_IN_IDX
  // gpio_matrix_in(pin_number, *_IN_IDX, false);
  return 0;
}

// Lua: gpiomatrix.gpioOutToPeriphIn(gpio, periph)
// Example:
//   -- Map LEDC GPIO output pin to Pulse Counter peripheral 
//   gpiomatrix.gpioOutToPeriphIn(
//     gm.pinLedc, -- GPIO
//     gpiomatrix.PCNT_SIG_CH0_IN0_IDX -- Peripheral
//   )
static int gpiomatrix_gpioOutToPeriphIn( lua_State *L ) {

  int gpio = luaL_checkint (L, 1);
  int periph = luaL_checkint (L, 2);

  // Connect the input functionality of a peripheral to the pin. This allows the peripheral to 
  // read the signal indicated from this pin.
  gpio_matrix_in(gpio, periph, false);

  return 0;
}

// static int gpiomatrix_iomuxGpioOutToPeriphIn( lua_State *L ) {

//   int gpio = luaL_checkint (L, 1);
//   int periph = luaL_checkint (L, 2);

//   // Connect the input functionality of a peripheral to the pin. This allows the peripheral to 
//   // read the signal indicated from this pin.
//   gpio_matrix_in(gpio, periph, false);

//   return 0;
// }

// Lua: gpiomatrix.setDir(gpio, dir)
static int gpiomatrix_setDir( lua_State *L ) {

  int gpio = luaL_checkint (L, 1);
  int dir = luaL_checkint (L, 2);

  // Connect the pin to the GPIO matrix.
  // PIN_FUNC_SELECT(GPIO_PIN_MUX_REG[pin_number], PIN_FUNC_GPIO);
  // Set the direction. GPIO_MODE_INPUT always makes it an input, GPIO_MODE_OUTPUT always makes it 
  // an output, GPIO_MODE_INPUT_OUTPUT lets the peripheral decide what direction it has. You usually 
  // want the last one.
  gpio_set_direction(gpio, dir);

  return 0;
}

// Lua: gpio.write(gpio, 0 || 1)
/*
static int lgpio_write (lua_State *L)
{
  int gpio = luaL_checkint (L, 1);
  int level = luaL_checkint (L, 2);
  check_err (L, gpio_set_level (gpio, level));
  return 0;
}
*/

static int gpiomatrix_init (lua_State *L)
{
  return 0;
}


LROT_BEGIN(gpiomatrix)
  LROT_FUNCENTRY( periphOutToGpioIn,       gpiomatrix_periphOutToGpioIn )
  LROT_FUNCENTRY( gpioOutToPeriphIn,       gpiomatrix_gpioOutToPeriphIn )
  LROT_FUNCENTRY( setDir,                  gpiomatrix_setDir )

  // *_OUT_IDX for periphOutToGpioIn()
  LROT_NUMENTRY ( RMT_SIG_OUT0_IDX,          RMT_SIG_OUT0_IDX )
  LROT_NUMENTRY ( RMT_SIG_OUT1_IDX,          RMT_SIG_OUT1_IDX )
  LROT_NUMENTRY ( RMT_SIG_OUT2_IDX,          RMT_SIG_OUT2_IDX )
  LROT_NUMENTRY ( RMT_SIG_OUT3_IDX,          RMT_SIG_OUT3_IDX )
  LROT_NUMENTRY ( RMT_SIG_OUT4_IDX,          RMT_SIG_OUT4_IDX )
  LROT_NUMENTRY ( RMT_SIG_OUT5_IDX,          RMT_SIG_OUT5_IDX )
  LROT_NUMENTRY ( RMT_SIG_OUT6_IDX,          RMT_SIG_OUT6_IDX )
  LROT_NUMENTRY ( RMT_SIG_OUT7_IDX,          RMT_SIG_OUT7_IDX )
  LROT_NUMENTRY ( LEDC_HS_SIG_OUT0_IDX,          LEDC_HS_SIG_OUT0_IDX )
  LROT_NUMENTRY ( LEDC_HS_SIG_OUT1_IDX,          LEDC_HS_SIG_OUT1_IDX )
  LROT_NUMENTRY ( LEDC_HS_SIG_OUT2_IDX,          LEDC_HS_SIG_OUT2_IDX )
  LROT_NUMENTRY ( LEDC_HS_SIG_OUT3_IDX,          LEDC_HS_SIG_OUT3_IDX )
  LROT_NUMENTRY ( LEDC_HS_SIG_OUT4_IDX,          LEDC_HS_SIG_OUT4_IDX )
  LROT_NUMENTRY ( LEDC_HS_SIG_OUT5_IDX,          LEDC_HS_SIG_OUT5_IDX )
  LROT_NUMENTRY ( LEDC_HS_SIG_OUT6_IDX,          LEDC_HS_SIG_OUT6_IDX )
  LROT_NUMENTRY ( LEDC_HS_SIG_OUT7_IDX,          LEDC_HS_SIG_OUT7_IDX )

  // *_IN_IDX for gpioOutToPeriphIn()
  LROT_NUMENTRY ( PCNT_SIG_CH0_IN0_IDX,          PCNT_SIG_CH0_IN0_IDX )
  LROT_NUMENTRY ( PCNT_SIG_CH0_IN1_IDX,          PCNT_SIG_CH0_IN1_IDX )
  LROT_NUMENTRY ( PCNT_SIG_CH0_IN2_IDX,          PCNT_SIG_CH0_IN2_IDX )
  LROT_NUMENTRY ( PCNT_SIG_CH0_IN3_IDX,          PCNT_SIG_CH0_IN3_IDX )
  LROT_NUMENTRY ( PCNT_SIG_CH0_IN4_IDX,          PCNT_SIG_CH0_IN4_IDX )
  LROT_NUMENTRY ( PCNT_SIG_CH0_IN5_IDX,          PCNT_SIG_CH0_IN5_IDX )
  LROT_NUMENTRY ( PCNT_SIG_CH0_IN6_IDX,          PCNT_SIG_CH0_IN6_IDX )
  LROT_NUMENTRY ( PCNT_SIG_CH0_IN7_IDX,          PCNT_SIG_CH0_IN7_IDX )
  LROT_NUMENTRY ( PCNT_SIG_CH1_IN0_IDX,          PCNT_SIG_CH1_IN0_IDX )
  LROT_NUMENTRY ( PCNT_CTRL_CH0_IN0_IDX,          PCNT_CTRL_CH0_IN0_IDX )
  LROT_NUMENTRY ( PCNT_CTRL_CH0_IN1_IDX,          PCNT_CTRL_CH0_IN1_IDX )
  LROT_NUMENTRY ( PCNT_CTRL_CH0_IN2_IDX,          PCNT_CTRL_CH0_IN2_IDX )
  LROT_NUMENTRY ( PCNT_CTRL_CH0_IN3_IDX,          PCNT_CTRL_CH0_IN3_IDX )
  LROT_NUMENTRY ( PCNT_CTRL_CH0_IN4_IDX,          PCNT_CTRL_CH0_IN4_IDX )
  LROT_NUMENTRY ( PCNT_CTRL_CH0_IN5_IDX,          PCNT_CTRL_CH0_IN5_IDX )
  LROT_NUMENTRY ( PCNT_CTRL_CH0_IN6_IDX,          PCNT_CTRL_CH0_IN6_IDX )
  LROT_NUMENTRY ( PCNT_CTRL_CH0_IN7_IDX,          PCNT_CTRL_CH0_IN7_IDX )

  // For setDir()
  LROT_NUMENTRY ( OUT,          GPIO_MODE_OUTPUT )
  LROT_NUMENTRY ( IN,           GPIO_MODE_INPUT )
  LROT_NUMENTRY ( IN_OUT,       GPIO_MODE_INPUT_OUTPUT )
  LROT_NUMENTRY ( IN_OUT_OD,    GPIO_MODE_INPUT_OUTPUT_OD )
  LROT_NUMENTRY ( OUT_OD,       GPIO_MODE_OUTPUT_OD )

LROT_END(gpiomatrix, NULL, 0)

NODEMCU_MODULE(GPIOMATRIX, "gpiomatrix", gpiomatrix, gpiomatrix_init);
