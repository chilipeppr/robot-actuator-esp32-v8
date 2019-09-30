/* 
RMT TX (Remote Control Transmit) module for ESP32 to allow interfacing from Lua to the RMT hardware
Authored by: ChiliPeppr (John Lauer) 2019

ESP-IDF docs for RMT
https://docs.espressif.com/projects/esp-idf/en/latest/api-reference/peripherals/rmt.html

ESP32 has a pulse generating sub-system called Remote Control that lets you define
a list of pulses with specific durations and offload them to the hardware so your main
CPU is not being used to control the pulse timing. This can be used to send infrared LED
signals, or even control stepper motors with acceleration/deceleration step pulses, or
many other pulse generating use cases.

This code is in the Public Domain (or CC0 licensed, at your option.)
Make modifications at will and freely.

Unless required by applicable law or agreed to in writing, this
software is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied.
*/

#include "module.h"
#include "common.h"
#include "lauxlib.h"
#include "lmem.h"
#include "platform.h"
#include "platform_rmt.h"
#include "task/task.h" 
#include "esp_log.h"
#include "lextra.h"
#include "driver/rmt.h"

#include <string.h>

static const char* TAG = "RmtTx";

typedef struct {
  bool is_initted;
  bool is_debug;
  uint8_t channel;
  uint8_t gpio;
  uint8_t memBlocks;
  uint16_t memCnt;
  uint8_t clkDiv;
  float nsPerTick;
  bool enLoop;
  bool enCarrier;
  uint8_t carrierDutyPct;
  rmt_carrier_level_t carrierLvl;
  uint32_t carrierFreqHz;
  bool enOutputIdle;
  rmt_idle_level_t idleLvl;
  int32_t cb_ref; // If a callback is provided, then we are using the ISR, otherwise we are just letting them poll
  bool isItems; // Keep track of whether we have items allocated
  rmt_item32_t *items; // Pointer to items they pass to write so we can hang onto it during ISR callbacks and free during unregister
  bool isDriverInstalled;
  uint16_t thresholdCtr;
  uint16_t offset;
} rmttx_struct_t;
typedef rmttx_struct_t *rmttx_t;

// array for all 8 channels of rmttx. these will be NULL unless there was a successful rmttx.create() from Lua
static rmttx_t rmttx_selfs[8];

/*
//Convert uint8_t type of data to rmt format data.
static void IRAM_ATTR u8_to_rmt(const void* src, rmt_item32_t* dest, size_t src_size, size_t wanted_num, size_t* translated_size, size_t* item_num)
{
    if(src == NULL || dest == NULL) {
        *translated_size = 0;
        *item_num = 0;
        return;
    }
    const rmt_item32_t bit0 = {{{ 32767, 1, 15000, 0 }}}; //Logical 0
    const rmt_item32_t bit1 = {{{ 32767, 1, 32767, 0 }}}; //Logical 1
    size_t size = 0;
    size_t num = 0;
    uint8_t *psrc = (uint8_t *)src;
    rmt_item32_t* pdest = dest;
    while (size < src_size && num < wanted_num) {
        for(int i = 0; i < 8; i++) {
            if(*psrc & (0x1 << i)) {
                pdest->val =  bit1.val; 
            } else {
                pdest->val =  bit0.val;
            }
            num++;
            pdest++;
        }
        size++;
        psrc++;
    }
    *translated_size = size;
    *item_num = num;
}
*/

// interrupt handler for RMT ISR
static rmt_isr_handle_t rmttx_intr_handle;

// Task ID to get ISR interrupt back into Lua callback
static task_handle_t rmttx_task_id;

// This interrupt is called when a threshold event occurs on the RMT transmitting
// so we can fill more data. It is also called at the end of the transmission.
static void IRAM_ATTR rmttx_isr(void *arg) {
  
  // Get the RMT channel status, usually used in ISR to decide which pads are ‘touched’.
  uint32_t intr_st = RMT.int_st.val;

  // ESP_EARLY_LOGI(TAG, "rmttx_isr. intr_st: %d", intr_st);

  uint32_t i = 0;
  uint8_t channel;

  // loop thru all 32 bits of the interrupt state intr_st
  for(i = 0; i < 32; i++) {
    // the bits less than 24 are tx end, rx end, and err events
    if (i < 24) {

      // if the bit is set for the current interrupt state, check it out for clearing
      if (intr_st & BIT(i)) {
        channel = i / 3;  // if 0, 0/3 = 0, if 1, 1/3 = 0.33 so 0, etc.

        // get our own selfs object for this channel
        rmttx_t tx = rmttx_selfs[channel];

        if (NULL == tx) {
          // if we got an interrupt for a channel we don't have a self for, that doesn't make sense
          // although we are in a shared ISR, so maybe it came from some other module. let's ignore
          // it, although for now clear its flag (which could mess stuff up, so perhaps comment out flag clear line below)
          // ESP_EARLY_LOGE(TAG, "Got TX END event for channel: %d that we are not managing. Huh?", channel);
          // RMT.int_clr.val = BIT(i);
          continue;
        }

        // the flags are laid out as tx end, rx end, and err events so 0/1/2
        switch(i % 3) {
            // TX END
            case 0:
                // ESP_EARLY_LOGI(TAG, "TX END. Will do cb here for channel: %d", channel);
                task_post_high(rmttx_task_id, 1 << 8 | channel );
                break;
            //ERR
            case 2:
                ESP_EARLY_LOGE(TAG, "RMT[%d] ERR", channel);
                ESP_EARLY_LOGE(TAG, "status: 0x%08x", RMT.status_ch[channel]);
                RMT.int_ena.val &= (~(BIT(i)));
                break;
            default:
                break;
        }
        RMT.int_clr.val = BIT(i);
      }
    } else {
      // these bits are >=24, which are the threshold events
      if(intr_st & (BIT(i))) {

        // this means we have a threshold event interrupt
        channel = i - 24; // the i is ordered correctly now from channel 0 to 8
        rmttx_t tx = rmttx_selfs[channel];
        // clear the interrupt so we don't keep getting ISR callbacks
        RMT.int_clr.val = BIT(i);

        // if we don't have a rmttx_selfs for this, even though we got an interrupt, ignore
        if (tx == NULL) {
          //skip
        } else {
          // ESP_EARLY_LOGE(TAG, "Load more RMT data here for channel: %d", channel);
          task_post_high(rmttx_task_id, 2 << 8 | channel );

        }
      }
    }
  }
  

  // task_post_high(rmttx_task_id, intr_st );

  /*
  // Loop thru all 8 channels to see which one we got this event for
  for (rmt_channel_t channel = 0; channel < RMT_CHANNEL_MAX; channel++) {

    // Check the interrupt state bit for channel x's rmt_chX_tx_thr_event_int_raw when mt_chX_tx_thr_event_int_ena is set to 1.
    if ((intr_st & (BIT(channel+24))) && (rmttx_selfs[channel] != NULL)) {
      RMT.int_clr.val = BIT(channel+24);

      // When channel0-7 sends more than reg_rmt_tx_lim_chX data then channel0-7 produce the relative interrupt.
      uint32_t data_sub_len = RMT.tx_lim_ch[channel].limit;

      // post using lua task posting technique
      // on lua_open we set rmttx_task_id as a method which gets called
      // by Lua after task_post_high with reference to this self object and then we can steal the 
      // callback_ref and then it gets called by lua_call where we get to add our args
      uint32_t rmttx_intr;
      rmttx_intr = data_sub_len << 8 | channel; // bit shift data_sub_len 8 spots. channel is 1 byte.
      task_post_high(rmttx_task_id, rmttx_intr );

    }
  }
  */

  // esp_err_t rmt_fill_tx_items(rmt_channel_t channel, const rmt_item32_t *item, uint16_t item_num, uint16_t mem_offset)

}

/*
This method gets called from the IRAM interuppt method via Lua's task queue. That lets the interrupt 
run clean while this method gets called at a lower priority to not break the IRAM interrupt high priority.
We will do the actual callback here for the user.
The format of the callback to your Lua code is:
  function onEvent(channel, data_sub_len)
*/
static void rmttx_task(task_param_t param, task_prio_t prio)
{
  // ESP_LOGI(TAG, "rmttx_task. param: %d", param);

  (void)prio;

  // we bit packed the channel number and data_sub_len into 1 uint32_t in the IRAM interrupt so need to unpack here
  uint8_t channel = (uint32_t)param & 0xffu;
  uint32_t flag = ((uint32_t)param >> 8);  // flag 1 is tx end, flag 2 is threshold event
  // ESP_LOGI(TAG, "About to do callback for channel %d with flag: %d", channel, flag);

  // get the self object for this channel. it has our callback.
  rmttx_t tx = rmttx_selfs[channel];
  // if (tx->is_debug) ESP_LOGI(TAG, "About to do callback for channel %d with cb %d", channel, tx->cb_ref);

  lua_State *L = lua_getstate ();
  if (tx->cb_ref != LUA_NOREF) {
    // we have a callback
    lua_rawgeti (L, LUA_REGISTRYINDEX, tx->cb_ref);
    const char* funcName = lua_tostring(L, -1);

    lua_pushinteger (L, channel);
    lua_pushinteger (L, flag);
    if (flag == 2) {
      lua_pushinteger (L, tx->thresholdCtr);
    } else {
      lua_pushnil (L);
    }
    // call the cb_ref the user gave us during create()
    /* do the call (3 arguments, 0 results) */
    if (lua_pcall(L, 3, 0, 0) != 0) {
      ESP_LOGI(TAG, "error running callback function `f': %s", funcName);
    }
  } else {
    if (tx->is_debug) ESP_LOGI(TAG, "Could not find cb for channel %d with cb %d with flag: %d", channel, tx->cb_ref, flag);
  }

}


/* 
Lua sample code:
tx = rmttx.create({
  channel = 0, -- 0 thru 7 supported
  gpio = 4, -- The GPIO pin to transmit the pulses on
  cb = myfunc, -- Callback to receive events
  memBlocks = 2, -- Number of memory blocks to use. Defaults to 1. 8 blocks available.
  clkDiv = 255, -- 80Mhz clock. clkDiv of 255 is 80,000,000/255 = 313,725 Hz = 0.0031875 ms per tick (3187.5 ns)
  enLoop = false, -- Transmit the data items in a loop
  enCarrier = false, -- Enable the RMT carrier signal 
  carrierDutyPct = 50, -- Duty cycle of the carrier signal in percent (%), i.e. 50
  carrierLvl = , -- Level of the RMT output, when the carrier is applied
  enOutputIdle = , -- Enable the RMT output if idle
  idleLvl = , -- Set the signal level on the RMT output if idle
  carrierFreqHz = 100, -- Set the carrier signal
  isDebug = true
})

Notes on the memBlocks paramter:
As you use blocks they are not available for other RMT objects. The more blocks, 
the less ISR callbacks required to transmit data, thus less load on your main CPU.
*/
static int rmttx_create( lua_State *L ) {

  // Create a temporary rmttx_t object 
  rmttx_struct_t tx = {.cb_ref=LUA_NOREF, .is_initted=false, .is_debug=false, .isItems = false, .isDriverInstalled = false, .offset = 0};

  luaL_checkanytable (L, 1);

  tx.is_debug = opt_checkbool(L, "isDebug", false);
  tx.channel = opt_checkint_range(L, "channel", 0, RMT_CHANNEL_0, RMT_CHANNEL_MAX);
  tx.gpio = opt_checkint_range(L, "gpio", 0, 0, 39);
  tx.memBlocks = opt_checkint_range(L, "memBlocks", 1, 1, 8);
  tx.clkDiv = opt_checkint_range(L, "clkDiv", 1, 1, 255);
  tx.enLoop = opt_checkbool(L, "enLoop", false);
  tx.enCarrier = opt_checkbool(L, "enCarrier", false);
  tx.carrierDutyPct = opt_checkint_range(L, "carrierDutyPct", 50, 0, 100);
  tx.carrierFreqHz = opt_checkint_range(L, "carrierFreqHz", 611, 611, 1000000);
  tx.carrierLvl = opt_checkint_range(L, "carrierLvl", RMT_CARRIER_LEVEL_LOW, RMT_CARRIER_LEVEL_LOW, RMT_CARRIER_LEVEL_HIGH);
  tx.enOutputIdle = opt_checkbool(L, "enOutputIdle", false);
  tx.idleLvl = opt_checkint_range(L, "idleLvl", RMT_IDLE_LEVEL_LOW, RMT_IDLE_LEVEL_LOW, RMT_IDLE_LEVEL_HIGH);
  
  // See if they gave us a callback
  // bool isCallback = true;
  lua_getfield(L, 1, "cb");
  if lua_isnoneornil(L, -1) {
    // user did not provide a callback. that's ok. just don't give them one.
    // isCallback = false;
    if (tx.is_debug) ESP_LOGI(TAG, "No callback provided. Not turning on interrupt." );
  } else {
    luaL_argcheck(L, lua_type(L, -1) == LUA_TFUNCTION || lua_type(L, -1) == LUA_TLIGHTFUNCTION, -1, "Cb must be function");
    
    //get the lua function reference
    luaL_unref(L, LUA_REGISTRYINDEX, tx.cb_ref);
    lua_pushvalue(L, -1);
    tx.cb_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    if (tx.is_debug) ESP_LOGI(TAG, "Cb good." );
  }

  // if (tx.is_debug) ESP_LOGI(TAG, "isDebug: %d, channel: %d, gpio: %d, memBlocks: %d, clkDiv: %d, enLoop: %d, enCarrier: %d", 
  //   tx.is_debug, tx.channel, tx.gpio, tx.memBlocks, tx.clkDiv, tx.enLoop, tx.enCarrier);
  // if (tx.is_debug) ESP_LOGI(TAG, "carrierDutyPct: %d, carrierLvl: %d, carrierFreqHz: %d, enOutputIdle: %d, idleLvl: %d", 
  //   tx.carrierDutyPct, tx.carrierLvl, tx.carrierFreqHz, tx.enOutputIdle, tx.idleLvl);

  // Figure out nanoseconds per tick based on clkDiv they passed us
  // APB clock is 80Mhz
  // tx.nsPerTick = (1 / (80000000 / tx.clkDiv)) * 1000000000;
  tx.nsPerTick = (1.0 / (800.0 / tx.clkDiv)) * 10000.0;
  if (tx.is_debug) ESP_LOGI(TAG, "Nanoseconds per tick: %f", tx.nsPerTick);

  //esp_err_t rmt_config(const rmt_config_t *rmt_param)
  //esp_err_t rmt_driver_install(rmt_channel_t channel, size_t rx_buf_size, int intr_alloc_flags)

  rmt_config_t config;
  config.rmt_mode = RMT_MODE_TX;
  config.channel = tx.channel;
  config.gpio_num = tx.gpio;
  config.mem_block_num = tx.memBlocks;
  config.clk_div = tx.clkDiv;

  config.tx_config.loop_en = tx.enLoop;
  config.tx_config.carrier_en = tx.enCarrier;
  config.tx_config.idle_output_en = tx.enOutputIdle;
  config.tx_config.idle_level = tx.idleLvl;

  if (tx.enCarrier) {
    config.tx_config.carrier_duty_percent = tx.carrierDutyPct;
    // 611 Hz is the minimum, that can be set
    // with current implementation of the RMT API
    config.tx_config.carrier_freq_hz = tx.carrierFreqHz;
    config.tx_config.carrier_level = tx.carrierLvl;
  }

  // we need to reserve this channel at the platform level so other modules
  // know we're using this RMT channel, i.e. ws2812 knows we have it or vice versa

  esp_err_t err = rmt_config(&config);
  if (err == ESP_ERR_INVALID_ARG) {
    return luaL_error( L, "invalid args" );
  }

  /*
  // rmt_driver_install(rmt_channel_t channel, size_t rx_buf_size, int intr_alloc_flags)
  // Flags for the RMT driver interrupt handler. Pass 0 for default flags.
  err = rmt_driver_install(config.channel, 0, 0);
  if (err == ESP_ERR_INVALID_STATE) {
    return luaL_error( L, "Driver is already installed" );
  } else if (err == ESP_ERR_NO_MEM) {
    return luaL_error( L, "Memory allocation failure" );
  } else if (err == ESP_ERR_INVALID_ARG ) {
    return luaL_error( L, "invalid args" );
  }
  tx.isDriverInstalled = true;
  */

  // Init rmt translator and register user callback. The callback will convert the raw data 
  // that needs to be sent to rmt format. If a channel is initialized more than once, the 
  // user callback will be replaced by the later.
  // err = rmt_translator_init(config.channel, u8_to_rmt);
  // if (err == ESP_FAIL ) {
  //   return luaL_error( L, "Init fail on translator" );
  // }

  // Now create our Lua version of this data to pass back
  rmttx_t tx2 = (rmttx_t)lua_newuserdata(L, sizeof(rmttx_struct_t));
  if (!tx2) return luaL_error(L, "not enough memory");
  luaL_getmetatable(L, "rmttx.pctr");
  lua_setmetatable(L, -2);
  tx2->is_initted = true;
  tx2->is_debug = tx.is_debug;
  // tx2->cb_ref = tx.cb_ref;
  tx2->channel = tx.channel;
  tx2->gpio = tx.gpio;
  tx2->memBlocks = tx.memBlocks;
  tx2->memCnt = tx2->memBlocks * 64;
  tx2->clkDiv = tx.clkDiv;
  tx2->enLoop = tx.enLoop;
  tx2->enCarrier = tx.enCarrier;
  tx2->carrierDutyPct = tx.carrierDutyPct;
  tx2->carrierLvl = tx.carrierLvl;
  tx2->enOutputIdle = tx.enOutputIdle;
  tx2->idleLvl = tx.idleLvl;
  tx2->isItems = tx.isItems;
  tx2->isDriverInstalled = tx.isDriverInstalled;
  tx2->cb_ref = tx.cb_ref;
  tx2->offset = tx.offset;

  // store this in our selfs array so we can find it during the ISR callback
  rmttx_selfs[tx2->channel] = tx2;

  if (tx.is_debug) ESP_LOGI(TAG, "isDebug: %d, channel: %d, gpio: %d, cb: %d, memBlocks: %d, clkDiv: %d, enLoop: %d, enCarrier: %d", 
    tx.is_debug, tx.channel, tx.gpio, tx.cb_ref, tx.memBlocks, tx.clkDiv, tx.enLoop, tx.enCarrier);
  if (tx.is_debug) ESP_LOGI(TAG, "carrierDutyPct: %d, carrierLvl: %d, carrierFreqHz: %d, enOutputIdle: %d, idleLvl: %d", 
    tx.carrierDutyPct, tx.carrierLvl, tx.carrierFreqHz, tx.enOutputIdle, tx.idleLvl);

  return 1;
}

// Get the rmttx.pctr object from the stack which is the struct rmttx_t
static rmttx_t rmttx_get( lua_State *L, int stack )
{
  return (rmttx_t)luaL_checkudata(L, stack, "rmttx.pctr");
}

// static int stack_dump( lua_State *L ) {
//   int i;
//   int top = lua_gettop(L);
//   for (i = 1; i <= top; i++) {  /* repeat for each level */
//     int t = lua_type(L, i);
//     switch (t) {

//       case LUA_TSTRING:  /* strings */
//         ESP_LOGI(TAG, "`%s'", lua_tostring(L, i));
//         break;

//       case LUA_TBOOLEAN:  /* booleans */
//         if (lua_toboolean(L, i)) {
//           ESP_LOGI(TAG, "true");
//         } else {
//           ESP_LOGI(TAG, "false");
//         }
//         break;

//       case LUA_TNUMBER:  /* numbers */
//         ESP_LOGI(TAG, "%g", lua_tonumber(L, i));
//         break;

//       default:  /* other values */
//         ESP_LOGI(TAG, "stack index: %d, type: %s", i, lua_typename(L, t));
//         break;

//     }
//     ESP_LOGI(TAG, "-");  /* put a separator */
//   }
//   ESP_LOGI(TAG, "end\n");  /* end the listing */

//   return 0;
// }

static float rmttx_getNsPerTickForClkDiv_raw(int clkDiv) {
  return (1.0 / (80000000.0 / clkDiv)) * 1000000000.0;
}

// Lua: getNsPerTickForClkDiv(clkDiv)
// Pass in a clock divider and we'll calculate how many nanoseconds each tick is
static int rmttx_getNsPerTickForClkDiv( lua_State *L ) {

  // stack_dump(L);

  // Get clkDiv param -- first arg after self arg
  int clkDiv = luaL_checkinteger(L, 1);

  float nsPerTick = rmttx_getNsPerTickForClkDiv_raw(clkDiv);
  // ESP_LOGI(TAG, "nsPerTick: %f", nsPerTick);
  lua_pushnumber(L, nsPerTick);
  return 1;
}

// Lua: getClkDivForNsPerTick(nanoseconds)
// Pass in a desired tick length in nanoseconds and we'll suggest the best clock divider
static int rmttx_getClkDivForNsPerTick( lua_State *L ) {

  // Get ns param -- first arg after self arg
  int ns = luaL_checkinteger(L, 1);

  // -- APBClk of 80Mhz / clock divider = new clock
  // -- 1 / new clock = tick length per second
  // -- tick len per second * 1,000,000,000 = tick len per nanosecond
  // -- nsPerTick = (1 / (80000000 / clkDiv)) * 1000000000
  // -- nsPerTick / 1000000000 = 1 / (80000000 / clkDiv)
  // -- nsPerTick / 1000000000 * 80000000 / clkDiv = 1
  // -- nsPerTick / 1000000000 * 80000000 = 1 * clkDiv
  // -- nsPerTick / 1000000000 * 80000000 = clkDiv
  float apbClk = 80000000;
  float secToNs = 1000000000;
  float clkDiv = ns / secToNs * apbClk;
  // print("clkDiv:", clkDiv)
  if (clkDiv < 1) {
    clkDiv = 1; // set to lowest
  } else if (clkDiv > 255) {
    clkDiv = 255; // set to highest
  }
  float nsPerTick = rmttx_getNsPerTickForClkDiv_raw(clkDiv);
  // ESP_LOGI(TAG, "Suggested clkDiv: %d, nsPerTick: %f", (uint8_t)clkDiv, nsPerTick);
  lua_pushnumber(L, (uint8_t)clkDiv);
  lua_pushnumber(L, nsPerTick);
  return 2;
}

// Lua:
// tx:writeRawStart({32767,1,32767,0})
// Write in raw mode where you get callbacks and have to keep re-filling the data. 
// writeRawStart() and writeRawFill() work together. You must call writeRawStart() first 
// to send in your first full chunk of data. You will get a callback after half are sent. On each
// callback call writeRawFill() to fill up half of the buffer with the next chunk of fresh data. 
// Send in an RMT item of {0,0,0,0} to end the sequence.
// You will also get a callback when done with the sequence.
static int rmttx_write_raw_start(lua_State *L) {
  // get our object that contains all of our info for this channel
  rmttx_t tx = rmttx_get(L, 1);
  if (tx->is_debug) ESP_LOGI(TAG, "About to do writeRawStart()" );
  
  // stack_dump(L);

  // current top obj is now our dur0/lvl0/dur1/lvl1 array
  luaL_checkanytable(L, 2);

  // get count of items in table
  size_t len = lua_objlen(L,2);

  // make sure divisible by 4
  // if (tx->is_debug) ESP_LOGI(TAG, "Number of items: %d", len );
  if (len % 4 != 0) {
    return luaL_error( L, "Number of items is not divisible by four. You must provide {dur0, lvl0, dur1, lvl1} per RMT pulse." );
  }

  // the array passed in is rows of dur0, lvl0, dur1, lvl1 so the actual amount of RMT items
  // is the array length divided by 4
  size_t item_cnt = len/4;

  // the data must fit into the memBlocks allocated
  // so check for them
  if (tx->is_debug) ESP_LOGI(TAG, "Checking memBlocks");
  size_t memCnt = tx->memBlocks * 64; // 64 rmt_item32_t's per block
  if (item_cnt > memCnt) {
    return luaL_error(L, "The data you provided is too large for the memBlocks you allocated. data byte count: %d, memBlocks: %d, memBlocks byte count: %d", item_cnt, tx->memBlocks, memCnt );
  } else {
    if (tx->is_debug) ESP_LOGI(TAG, "memBlocks is good. Data byte count: %d, memBlocks: %d, memBlocks byte count: %d", item_cnt, tx->memBlocks, memCnt );
  }

  // iterate table passed in, converting to rmt_item32_t
  // rmt_item32_t items[len/4];
  if (tx->isItems) {
    if (tx->is_debug) ESP_LOGI(TAG, "Trying to alloc mem for items, but we must have had a prev write, so have to free that mem first.");
    luaM_free(L, tx->items);
  }
  tx->items = luaM_malloc(L, sizeof(rmt_item32_t) * item_cnt);
  tx->isItems = true;
  if (tx->is_debug) ESP_LOGI(TAG, "Allocated items mem.");
  
  // need a nil to iterate table correctly
  lua_pushnil(L);

  // get nanoseconds per tick
  float nsPerTick = (1.0 / (80000000.0 / tx->clkDiv)) * 1000000000.0;
  if (tx->is_debug) ESP_LOGI(TAG, "clkDiv: %d, nsPerTick: %f", tx->clkDiv, nsPerTick);

  int ctr = 0;
  int ctrInner = 0;
  float totalDuration = 0.0;
  while (lua_next(L, -2) != 0)
  {
    lua_pushvalue(L, -1); // copy, so lua_tonumber() doesn't break iter
    int val = lua_tointeger(L, -1);
    if (ctrInner == 0 || ctrInner == 2) {
      if (val >= 0 && val <= 32767) {
        // we have the duration0 or duration1
        if (ctrInner == 0) {
          tx->items[ctr].duration0 = val;
        } else {
          tx->items[ctr].duration1 = val;
        }
        totalDuration += val * nsPerTick; // keep running sum
      } else {
        return luaL_error( L, "Index: %d duration must be >= 0 and <= 32767. duration was: %d", ctr, val );
      }
    } else {
      if (val == 0 || val == 1) {
        if (ctrInner == 1) {
          tx->items[ctr].level0 = val;
        } else {
          tx->items[ctr].level1 = val;
        }
      } else {
        return luaL_error( L, "Index: %d level must be 0 or 1. level was: %d", ctr, val );
      }
    }

    lua_pop(L, 2); // leave key
    ctrInner++;
    if (ctrInner == 4) {
      // if (tx->is_debug) ESP_LOGI(TAG, "index: %d, dur0: %d (%f ns), lvl0: %d, dur1: %d (%f ns), lvl1: %d", ctr, items[ctr].duration0, items[ctr].duration0 * nsPerTick, items[ctr].level0, items[ctr].duration1, items[ctr].duration1 * nsPerTick, items[ctr].level1 );
      ctr++;
      ctrInner = 0;
    }
  }
  if (tx->is_debug) ESP_LOGI(TAG, "Number of items: %d", ctr );
  if (tx->is_debug) ESP_LOGI(TAG, "Duration of pulses: %f ns (%f ms)", totalDuration, totalDuration / 1000000 );
  if (tx->is_debug) ESP_LOGI(TAG, "Sending on gpio: %d", tx->gpio);

  // user can't mix write() and writeRaw()
  if (tx->isDriverInstalled) {
    return luaL_error( L, "You cannot call writeRaw() if you called write() before and have the driver installed." );
  }

  // check that they have a callback otherwise this fails
  if (tx->cb_ref == LUA_NOREF) {
    return luaL_error( L, "You must have a callback set in the rmttx.create() method to do writeRaw().");
  }

  // Register ISR
  // esp_err_t rmt_isr_register(void (*fn)(void *), void *arg, int intr_alloc_flags, rmt_isr_handle_t *handle, )
  rmt_isr_register(rmttx_isr, NULL, PLATFORM_RMT_INTR_FLAGS, &rmttx_intr_handle );
  // rmt_isr_register(rmttx_isr, NULL, 0, &rmttx_intr_handle );

  // Get event when done transmitting
  // esp_err_t rmt_set_tx_intr_en(rmt_channel_t channel, bool en)
  // rmt_set_tx_intr_en(rmt_channel_t channel, bool en);
  rmt_set_tx_intr_en(tx->channel, true);

  // Get threshold event
  // esp_err_t rmt_set_tx_thr_intr_en(rmt_channel_t channel, bool en, uint16_t evt_thresh)
  // You want to set the threshold at half the size of the memBlocks provisioned to this channel
  uint16_t thresCnt = memCnt / 2;
  if (tx->is_debug) ESP_LOGI(TAG, "Threshold event set at byte count: %d", thresCnt);
  tx->thresholdCtr = thresCnt;
  rmt_set_tx_thr_intr_en(tx->channel, true, thresCnt);

  // void rmt_set_intr_enable_mask(uint32_t mask)
  // rmt_set_intr_enable_mask(uint32_t mask);
  // uint32_t mask;
  // rmt_set_intr_enable_mask( mask);

  // esp_err_t rmt_fill_tx_items(rmt_channel_t channel, const rmt_item32_t *item, uint16_t item_num, uint16_t mem_offset)
  rmt_fill_tx_items(tx->channel, tx->items, ctr, 0);

  // reset the offset in case there was already a writeRawStart/writeRawFill operation
  tx->offset = 0;
  // tx->offset = tx->memCnt / 2; // don't understand why we have to start our offset at half threshold
  if (tx->is_debug) ESP_LOGI(TAG, "offset: %d", tx->offset);

  // esp_err_trmt_tx_start(rmt_channel_tchannel, bool tx_idx_rst)
  rmt_tx_start(tx->channel, true);

  // rmt_write_items(tx->channel, tx->items, ctr, false);

  // free the memory
  // luaM_free(L, tx->items);
  // tx->isItems = false;

  return 0;
}

// Lua:
// tx:writeRawFill({32767,1,32767,0})
// Fill the memBlocks bytes. This is used during the callbacks from tx:writeRawStart() to inject more data.
static int rmttx_write_raw_fill( lua_State *L ) {

  // get our object that contains all of our info for this channel
  rmttx_t tx = rmttx_get(L, 1);
  // if (tx->is_debug) ESP_LOGI(TAG, "About to do writeRawFill()" );
  
  // stack_dump(L);

  // current top obj is now our dur0/lvl0/dur1/lvl1 array
  luaL_checkanytable(L, 2);

  // get count of items in table
  // size_t len = lua_objlen(L,2);

  // make sure divisible by 4
  // if (tx->is_debug) ESP_LOGI(TAG, "Number of items: %d", len );
  // if (len % 4 != 0) {
  //   return luaL_error( L, "Number of items is not divisible by four. You must provide {dur0, lvl0, dur1, lvl1} per RMT pulse." );
  // }

  // the array passed in is rows of dur0, lvl0, dur1, lvl1 so the actual amount of RMT items
  // is the array length divided by 4
  // size_t item_cnt = len/4;

  // the data must fit into the memBlocks allocated / 2 since this is a threshold write (half the memBlocks available)
  // so check for them
  // if (tx->is_debug) ESP_LOGI(TAG, "Checking memBlocks");
  // size_t memCnt = tx->memBlocks * 64; // 64 rmt_item32_t's per block
  // if (item_cnt > memCnt / 2) {
  //   return luaL_error(L, "The data you provided is too large for half of the memBlocks, which is the threshold for writeRawFill(). data byte count: %d, memBlocks: %d, half memBlocks byte count: %d", item_cnt, tx->memBlocks, memCnt / 2 );
  // } else {
  //   if (tx->is_debug) ESP_LOGI(TAG, "memBlocks is good. Data byte count: %d, memBlocks: %d, half memBlocks byte count: %d", item_cnt, tx->memBlocks, memCnt / 2 );
  // }

  // iterate table passed in, converting to rmt_item32_t
  // rmt_item32_t items[len/4];
  // if (tx->isItems) {
  //   if (tx->is_debug) ESP_LOGI(TAG, "Trying to alloc mem for items, but we must have had a prev write, so have to free that mem first.");
  //   luaM_free(L, tx->items);
  //   tx->isItems = false;
  // }
  // tx->items = luaM_malloc(L, sizeof(rmt_item32_t) * item_cnt);
  // tx->isItems = true;
  // if (tx->is_debug) ESP_LOGI(TAG, "Allocated items mem.");
  
  // need a nil to iterate table correctly
  lua_pushnil(L);

  // get nanoseconds per tick
  // float nsPerTick = (1.0 / (80000000.0 / tx->clkDiv)) * 1000000000.0;
  // if (tx->is_debug) ESP_LOGI(TAG, "clkDiv: %d, nsPerTick: %f", tx->clkDiv, nsPerTick);

  int ctr = 0;
  int ctrInner = 0;
  // float totalDuration = 0.0;

  // we are going to write direct to RMT memory in this loop to avoid mem alloc 
  rmt_item32_t item;

  while (lua_next(L, -2) != 0)
  {
    lua_pushvalue(L, -1); // copy, so lua_tonumber() doesn't break iter
    int val = lua_tointeger(L, -1);
    if (ctrInner == 0 || ctrInner == 2) {
      if (val >= 0 && val <= 32767) {
        // we have the duration0 or duration1
        if (ctrInner == 0) {
          // tx->items[ctr].duration0 = val;
          item.duration0 = val;
        } else {
          // tx->items[ctr].duration1 = val;
          item.duration1 = val;
        }
        // totalDuration += val * nsPerTick; // keep running sum
      } else {
        return luaL_error( L, "Index: %d duration must be >= 0 and <= 32767. duration was: %d", ctrInner, val );
      }
    } else {
      if (val == 0 || val == 1) {
        if (ctrInner == 1) {
          // tx->items[ctr].level0 = val;
          item.level0 = val;
        } else {
          // tx->items[ctr].level1 = val;
          item.level1 = val;
        }
      } else {
        return luaL_error( L, "Index: %d level must be 0 or 1. level was: %d", ctrInner, val );
      }
    }

    lua_pop(L, 2); // leave key
    ctrInner++;

    // see if we're done with this item
    if (ctrInner == 4) {
      // if (tx->is_debug) ESP_LOGI(TAG, "index: %d, dur0: %d (%f ns), lvl0: %d, dur1: %d (%f ns), lvl1: %d", ctr, items[ctr].duration0, items[ctr].duration0 * nsPerTick, items[ctr].level0, items[ctr].duration1, items[ctr].duration1 * nsPerTick, items[ctr].level1 );

      // write this to RMT memory so we can re-use rmt_item32_t item variable next time thru loop 
      rmt_fill_tx_items(tx->channel, &item, 1, tx->offset);
      if (tx->is_debug && ctr == 0) ESP_LOGI(TAG, "started fill, offset: %d", tx->offset);
      tx->offset += 1;

      // if our offset is now the size of the memBlocks, then set offset back to 0
      if (tx->offset == tx->memCnt) {
        tx->offset = 0;
      }

      ctr++;
      ctrInner = 0;
    }
  }
  // if (tx->is_debug) ESP_LOGI(TAG, "Duration of pulses: %f ns (%f ms)", totalDuration, totalDuration / 1000000 );
  
  // see what offset we're at
  // when we start, we send a full memBlock of data
  // if this is the first fillRaw() then tx->offset is at 0, so let's add tx->thresholdCtr after the fill

  // Ok, fill the memory now
  // if (tx->is_debug) ESP_LOGI(TAG, "Fill mem number of items: %d, offset: %d", ctr, tx->offset);

  // rmt_fill_tx_items(tx->channel, tx->items, ctr, tx->offset);


  return 0;
}

// // Lua:
// // tx:writeRawFill({32767,1,32767,0})
// // Fill the memBlocks bytes. This is used during the callbacks from tx:writeRawStart() to inject more data.
// static int rmttx_write_raw_fill( lua_State *L ) {

//   // get our object that contains all of our info for this channel
//   rmttx_t tx = rmttx_get(L, 1);
//   if (tx->is_debug) ESP_LOGI(TAG, "About to do writeRawFill()" );
  
//   // stack_dump(L);

//   // current top obj is now our dur0/lvl0/dur1/lvl1 array
//   luaL_checkanytable(L, 2);

//   // get count of items in table
//   size_t len = lua_objlen(L,2);

//   // make sure divisible by 4
//   // if (tx->is_debug) ESP_LOGI(TAG, "Number of items: %d", len );
//   if (len % 4 != 0) {
//     return luaL_error( L, "Number of items is not divisible by four. You must provide {dur0, lvl0, dur1, lvl1} per RMT pulse." );
//   }

//   // the array passed in is rows of dur0, lvl0, dur1, lvl1 so the actual amount of RMT items
//   // is the array length divided by 4
//   size_t item_cnt = len/4;

//   // the data must fit into the memBlocks allocated / 2 since this is a threshold write (half the memBlocks available)
//   // so check for them
//   if (tx->is_debug) ESP_LOGI(TAG, "Checking memBlocks");
//   size_t memCnt = tx->memBlocks * 64; // 64 rmt_item32_t's per block
//   if (item_cnt > memCnt / 2) {
//     return luaL_error(L, "The data you provided is too large for half of the memBlocks, which is the threshold for writeRawFill(). data byte count: %d, memBlocks: %d, half memBlocks byte count: %d", item_cnt, tx->memBlocks, memCnt / 2 );
//   } else {
//     if (tx->is_debug) ESP_LOGI(TAG, "memBlocks is good. Data byte count: %d, memBlocks: %d, half memBlocks byte count: %d", item_cnt, tx->memBlocks, memCnt / 2 );
//   }

//   // iterate table passed in, converting to rmt_item32_t
//   // rmt_item32_t items[len/4];
//   if (tx->isItems) {
//     if (tx->is_debug) ESP_LOGI(TAG, "Trying to alloc mem for items, but we must have had a prev write, so have to free that mem first.");
//     luaM_free(L, tx->items);
//     tx->isItems = false;
//   }
//   tx->items = luaM_malloc(L, sizeof(rmt_item32_t) * item_cnt);
//   tx->isItems = true;
//   if (tx->is_debug) ESP_LOGI(TAG, "Allocated items mem.");
  
//   // need a nil to iterate table correctly
//   lua_pushnil(L);

//   // get nanoseconds per tick
//   float nsPerTick = (1.0 / (80000000.0 / tx->clkDiv)) * 1000000000.0;
//   if (tx->is_debug) ESP_LOGI(TAG, "clkDiv: %d, nsPerTick: %f", tx->clkDiv, nsPerTick);

//   int ctr = 0;
//   int ctrInner = 0;
//   float totalDuration = 0.0;
//   while (lua_next(L, -2) != 0)
//   {
//     lua_pushvalue(L, -1); // copy, so lua_tonumber() doesn't break iter
//     int val = lua_tointeger(L, -1);
//     if (ctrInner == 0 || ctrInner == 2) {
//       if (val >= 0 && val <= 32767) {
//         // we have the duration0 or duration1
//         if (ctrInner == 0) {
//           tx->items[ctr].duration0 = val;
//         } else {
//           tx->items[ctr].duration1 = val;
//         }
//         totalDuration += val * nsPerTick; // keep running sum
//       } else {
//         return luaL_error( L, "Index: %d duration must be >= 0 and <= 32767. duration was: %d", ctr, val );
//       }
//     } else {
//       if (val == 0 || val == 1) {
//         if (ctrInner == 1) {
//           tx->items[ctr].level0 = val;
//         } else {
//           tx->items[ctr].level1 = val;
//         }
//       } else {
//         return luaL_error( L, "Index: %d level must be 0 or 1. level was: %d", ctr, val );
//       }
//     }

//     lua_pop(L, 2); // leave key
//     ctrInner++;
//     if (ctrInner == 4) {
//       // if (tx->is_debug) ESP_LOGI(TAG, "index: %d, dur0: %d (%f ns), lvl0: %d, dur1: %d (%f ns), lvl1: %d", ctr, items[ctr].duration0, items[ctr].duration0 * nsPerTick, items[ctr].level0, items[ctr].duration1, items[ctr].duration1 * nsPerTick, items[ctr].level1 );
//       ctr++;
//       ctrInner = 0;
//     }
//   }
//   if (tx->is_debug) ESP_LOGI(TAG, "Duration of pulses: %f ns (%f ms)", totalDuration, totalDuration / 1000000 );
  
//   // see what offset we're at
//   // when we start, we send a full memBlock of data
//   // if this is the first fillRaw() then tx->offset is at 0, so let's add tx->thresholdCtr after the fill

//   // Ok, fill the memory now
//   if (tx->is_debug) ESP_LOGI(TAG, "Fill mem number of items: %d, offset: %d", ctr, tx->offset);

//   rmt_fill_tx_items(tx->channel, tx->items, ctr, tx->offset);
//   tx->offset += tx->thresholdCtr;

//   // if our offset is now the size of the memBlocks, then set offset back to 0
//   if (tx->offset == memCnt) {
//     tx->offset = 0;
//   }

//   return 0;
// }

// Internal call
static int rmttx_write(bool isAsync, lua_State *L ) {

  // get our object that contains all of our info for this channel
  rmttx_t tx = rmttx_get(L, 1);
  // if (tx->is_debug) ESP_LOGI(TAG, "got tx self userdata obj" );
  
  // stack_dump(L);

  // current top obj is now our dur0/lvl0/dur1/lvl1 array
  luaL_checkanytable(L, 2);

  // get count of items in table
  size_t len = lua_objlen(L,2);

  // make sure divisible by 4
  // if (tx->is_debug) ESP_LOGI(TAG, "Number of items: %d", len );
  if (len % 4 != 0) {
    return luaL_error( L, "Number of items is not divisible by four. You must provide {dur0, lvl0, dur1, lvl1} per RMT pulse." );
  }

  // the array passed in is rows of dur0, lvl0, dur1, lvl1 so the actual amount of RMT items
  // is the array length divided by 4
  size_t item_cnt = len/4;

  // if they asked for a loop, then the data must fit into the memBlocks allocated
  // so check for them
  if (tx->enLoop) {
    if (tx->is_debug) ESP_LOGI(TAG, "enLoop asked for, so checking memBlocks");
    size_t memCnt = tx->memBlocks * 64; // 64 rmt_item32_t's per block
    if (item_cnt > memCnt) {
      return luaL_error(L, "You asked for a loop, but the data you provided is too large for the memBlocks you allocated. data byte count: %d, memBlocks: %d, memBlocks byte count: %d", item_cnt, tx->memBlocks, memCnt );
    }
  }

  // iterate table passed in, converting to rmt_item32_t
  // rmt_item32_t items[len/4];
  if (tx->isItems) {
    if (tx->is_debug) ESP_LOGI(TAG, "Trying to alloc mem for items, but we must have had a prev write, so have to free that mem first.");
    luaM_free(L, tx->items);
  }
  tx->items = luaM_malloc(L, sizeof(rmt_item32_t) * item_cnt);
  tx->isItems = true;
  if (tx->is_debug) ESP_LOGI(TAG, "Allocated items mem.");
  
  lua_pushnil(L);

  // get nanoseconds per tick
  float nsPerTick = (1.0 / (80000000.0 / tx->clkDiv)) * 1000000000.0;
  if (tx->is_debug) ESP_LOGI(TAG, "clkDiv: %d, nsPerTick: %f", tx->clkDiv, nsPerTick);

  int ctr = 0;
  int ctrInner = 0;
  float totalDuration = 0.0;
  while (lua_next(L, -2) != 0)
  {
    lua_pushvalue(L, -1); // copy, so lua_tonumber() doesn't break iter
    int val = lua_tointeger(L, -1);
    if (ctrInner == 0 || ctrInner == 2) {
      if (val >= 0 && val <= 32767) {
        // we have the duration0 or duration1
        if (ctrInner == 0) {
          tx->items[ctr].duration0 = val;
        } else {
          tx->items[ctr].duration1 = val;
        }
        totalDuration += val * nsPerTick; // keep running sum
      } else {
        return luaL_error( L, "Index: %d duration must be >= 0 and <= 32767. duration was: %d", ctr, val );
      }
    } else {
      if (val == 0 || val == 1) {
        if (ctrInner == 1) {
          tx->items[ctr].level0 = val;
        } else {
          tx->items[ctr].level1 = val;
        }
      } else {
        return luaL_error( L, "Index: %d level must be 0 or 1. level was: %d", ctr, val );
      }
    }

    lua_pop(L, 2); // leave key
    ctrInner++;
    if (ctrInner == 4) {
      // if (tx->is_debug) ESP_LOGI(TAG, "index: %d, dur0: %d (%f ns), lvl0: %d, dur1: %d (%f ns), lvl1: %d", ctr, items[ctr].duration0, items[ctr].duration0 * nsPerTick, items[ctr].level0, items[ctr].duration1, items[ctr].duration1 * nsPerTick, items[ctr].level1 );
      ctr++;
      ctrInner = 0;
    }
  }
  if (tx->is_debug) ESP_LOGI(TAG, "Number of items: %d", ctr );
  if (tx->is_debug) ESP_LOGI(TAG, "Duration of pulses: %f ns (%f ms)", totalDuration, totalDuration / 1000000 );
  if (tx->is_debug) ESP_LOGI(TAG, "Sending on gpio: %d", tx->gpio);

  // the drive could have been uninstalled from a previous async call
  // if it is, reinstall it
  if (tx->isDriverInstalled == false) {
    // rmt_driver_install(rmt_channel_t channel, size_t rx_buf_size, int intr_alloc_flags)
    // Flags for the RMT driver interrupt handler. Pass 0 for default flags.
    esp_err_t err = rmt_driver_install(tx->channel, 0, 0);
    if (err == ESP_ERR_INVALID_STATE) {
      return luaL_error( L, "Driver is already installed" );
    } else if (err == ESP_ERR_NO_MEM) {
      return luaL_error( L, "Memory allocation failure" );
    } else if (err == ESP_ERR_INVALID_ARG ) {
      return luaL_error( L, "invalid args" );
    }
    tx->isDriverInstalled = true;
    if (tx->is_debug) ESP_LOGI(TAG, "Installed driver cuz previously uninstalled.");
  }

  // esp_err_t rmt_write_items(rmt_channel_t channel, const rmt_item32_t *rmt_item, int item_num, bool wait_tx_done)
  rmt_write_items(tx->channel, tx->items, ctr, isAsync ? false : true);
  if (tx->is_debug) ESP_LOGI(TAG, "Sent.");

  if (tx->enLoop) {
    // if they want looping, we have to uninstall the driver or we get a double layer of pulses
    // not sure why actually, but uninstalling the driver seems to work
    
    // uninstall driver for this channel
    rmt_driver_uninstall(tx->channel);
    tx->isDriverInstalled = false;
    if (tx->is_debug) ESP_LOGI(TAG, "Uninstalled driver due to enLoop true.");
  }
  // free the memory
  // luaM_free(L, items);


  /*
  for (int i = 0; i < ctr; i++)
  {
    if (tx->is_debug) ESP_LOGI(TAG, "index: %d, dur0: %d, lvl0: %d, dur1: %d, lvl1: %d", i, 
      items[i].duration0, items[i].level0, items[i].duration1, items[i].level1);
  }
  */
  

  return 0;
}

// Lua:
// -- You need to write in duration0, lvl0, duration1, lvl1 pairs
// tx:writeSync({
//   32767,1,255,0, 
//   10000,1,32767,0, 
//   20000,1,0,0 
// })
// Blocks return until write is completed
static void rmttx_writeSync( lua_State *L ) {
  rmttx_write(false, L);
}

// Lua:
// -- You need to write in duration0, lvl0, duration1, lvl1 pairs
// tx:writeAsync({
//   32767,1,255,0, 
//   10000,1,32767,0, 
//   20000,1,0,0 
// })
// Returns immediately before write is completed
static void rmttx_writeAsync( lua_State *L ) {
  rmttx_write(true, L);
}

// Lua:
// tx:stop()
// RMT stop sending
static int rmttx_stop( lua_State *L ) {

  rmttx_t tx = rmttx_get(L, 1);

  // esp_err_t rmt_tx_stop(rmt_channel_t channel)
  rmt_tx_stop(tx->channel);
  
  return 0;

}

// Lua:
// tx:start(isIndexReset)
// RMT start sending data from memory
// isIndexReset: Set true to reset memory index for TX. Otherwise, transmitter will continue sending from the last index in memory.
static int rmttx_start( lua_State *L ) {

  rmttx_t tx = rmttx_get(L, 1);

  bool isIndexReset = false;

  // 1st param isIndexReset
  if (lua_isboolean(L,2)) {
    isIndexReset = lua_toboolean(L, 2);
    if (tx->is_debug) ESP_LOGI(TAG, "isIndexReset specified: %s.", isIndexReset ? "true" : "false");
  }

  /*
  // the drive could have been uninstalled from a previous async call
  // if it is, reinstall it
  if (tx->isDriverInstalled == false) {
    // rmt_driver_install(rmt_channel_t channel, size_t rx_buf_size, int intr_alloc_flags)
    // Flags for the RMT driver interrupt handler. Pass 0 for default flags.
    esp_err_t err = rmt_driver_install(tx->channel, 0, 0);
    if (err == ESP_ERR_INVALID_STATE) {
      return luaL_error( L, "Driver is already installed" );
    } else if (err == ESP_ERR_NO_MEM) {
      return luaL_error( L, "Memory allocation failure" );
    } else if (err == ESP_ERR_INVALID_ARG ) {
      return luaL_error( L, "invalid args" );
    }
    tx->isDriverInstalled = true;
    if (tx->is_debug) ESP_LOGI(TAG, "Installed driver cuz previously uninstalled.");
  }
  */

  // esp_err_t rmt_tx_start(rmt_channel_t channel, bool tx_idx_rst)
  rmt_tx_start(tx->channel, isIndexReset);
  
  return 0;

}

// Lua:
// tx:setLoop(isLoop)
// Set RMT tx loop mode. Enable RMT transmitter loop sending mode. 
// If set true, transmitter will continue sending from the first data to the last 
// data in channel 0-7 over and over again in a loop.
static int rmttx_setLoop( lua_State *L ) {

  rmttx_t tx = rmttx_get(L, 1);

  bool isLoop = false;

  // 1st param isLoop
  if (lua_isboolean(L,2)) {
    isLoop = lua_toboolean(L, 2);
    if (tx->is_debug) ESP_LOGI(TAG, "isLoop specified: %s.", isLoop ? "true" : "false");
  }

  // esp_err_t rmt_set_tx_loop_mode(rmt_channel_t channel, bool loop_en)
  rmt_set_tx_loop_mode(tx->channel, isLoop);
  
  return 0;

}

// Lua:
// tx:setPin(gpio) -- set GPIO number on-the-fly for RMT pulses to be sent on
static int rmttx_setPin( lua_State *L ) {

  // rmttx_t tx = rmttx_get(L, 1);

  //esp_err_t rmt_set_pin(rmt_channel_tchannel, rmt_mode_tmode, gpio_num_tgpio_num)
  // esp_err_t err = rmt_set_pin(tx->channel, rmt_mode_tmode, gpio_num_tgpio_num)
  
  return 0;

}

// // Lua:
// // rmttx.gpioMatrixOut()
// static int rmttx_gpio_matrix_out( lua_State *L ) {
//   gpio_matrix_in(PSRAM_INTERNAL_IO_28, SIG_IN_FUNC224_IDX, 0);
//   gpio_matrix_out( chain->gpio, SIG_, 0, 0 );

//   // rmt is set to output. the output gpio is connected to the RMT_SIG_OUT0_IDX + channel 
//   // so, for pulse counting on this, we should be able to gpio_matrix_in(pcnt_gpio, RMT_SIG_OUT0_IDX + channel)
//   gpio_set_direction(gpio_num, GPIO_MODE_OUTPUT);
//         gpio_matrix_out(gpio_num, RMT_SIG_OUT0_IDX + channel, 0, 0);
// }

// Lua: rmttx:unregister( self )
static int rmttx_unregister(lua_State* L) {
  rmttx_t tx = rmttx_get(L, 1);
  if (tx->is_debug) ESP_LOGI(TAG, "Unregistering");

  // stop sending, if it is (could be in a loop)
  // rmt_tx_stop(tx->channel);

  // uninstall driver for this channel
  if (tx->isDriverInstalled) {
    rmt_driver_uninstall(tx->channel);
    tx->isDriverInstalled = false;
  }

  // free the items memory
  if (tx->isItems) {
    luaM_free(L, tx->items);
    tx->isItems = false;
    ESP_LOGI(TAG, "Released items memory.");
  }

  // remove from selfs array
  rmttx_selfs[tx->channel] = NULL;  

  // if there was a callback, turn off ISR
//   if (tp->cb_ref != LUA_NOREF) {
//     touch_intrDisable(L);
    
//     touch_pad_isr_deregister(touch_intr_handler, NULL);

//     luaL_unref(L, LUA_REGISTRYINDEX, tp->cb_ref);
//     tp->cb_ref = LUA_NOREF;
    
//   } else {
//     // non-interrupt mode
//     if (tp->filterMs > 0) {
//       touch_pad_filter_stop();
//     }
//   }

//   touch_pad_deinit();
//   touch_self = NULL;

  return 0;
}

LROT_BEGIN(rmttx_dyn)
  // LROT_FUNCENTRY( write,         rmttx_write )
  
  LROT_FUNCENTRY( writeRawFill,   rmttx_write_raw_fill )
  LROT_FUNCENTRY( writeRawStart,  rmttx_write_raw_start )
  LROT_FUNCENTRY( setLoop,        rmttx_setLoop )
  LROT_FUNCENTRY( stop,           rmttx_stop )
  LROT_FUNCENTRY( start,          rmttx_start )
  LROT_FUNCENTRY( writeSync,      rmttx_writeSync )
  LROT_FUNCENTRY( writeAsync,     rmttx_writeAsync )
  LROT_FUNCENTRY( setPin,         rmttx_setPin )
  LROT_FUNCENTRY( __gc,           rmttx_unregister )
  LROT_TABENTRY ( __index,        rmttx_dyn )
LROT_END(rmttx_dyn, NULL, 0)

LROT_BEGIN(rmttx)

  LROT_FUNCENTRY( getClkDivForNsPerTick,  rmttx_getClkDivForNsPerTick )
  LROT_FUNCENTRY( getNsPerTickForClkDiv,  rmttx_getNsPerTickForClkDiv )
  LROT_FUNCENTRY( create,                 rmttx_create )
LROT_END(rmttx, NULL, 0)

int luaopen_rmttx(lua_State *L) {

  luaL_rometatable(L, "rmttx.pctr", (void *)rmttx_dyn_map);

  rmttx_task_id = task_get_id(rmttx_task);

  for (size_t i = 0; i < RMT_CHANNEL_MAX; i++)
  {
    rmttx_selfs[i] = NULL;
  }
  
  return 0;
}

NODEMCU_MODULE(RMTTX, "rmttx", rmttx, luaopen_rmttx);