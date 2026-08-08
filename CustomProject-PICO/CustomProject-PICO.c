#include <stdio.h>
#include "pico/stdlib.h"
#include "hardware/spi.h"
// #include "hardware/i2c.h"
// #include "hardware/dma.h"
#include "hardware/timer.h"
#include "pico/cyw43_arch.h"
#include "lwip/pbuf.h"
#include "lwip/tcp.h"
#include "wifi_config.h"

// SPI Defines
// We are going to use SPI 0, and allocate it to the following GPIO pins
// Pins can be changed, see the GPIO function select table in the datasheet for information on GPIO assignments
#define SPI_PORT spi0
#define PIN_MISO 16 //RX
#define PIN_CS 17
#define PIN_SCK 18
#define PIN_MOSI 19 // TX

#define TCP_PORT    4242                 /* must match the Python script */
#define IMAGE_BYTES (76800 * 2)          /* 153600 bytes (uint16 per pixel) */
 
typedef struct {
    struct tcp_pcb *pcb;
    ip_addr_t       remote_addr;
    const uint8_t  *data;        /* points at (uint8_t*)Storage */
    uint32_t        total;       /* IMAGE_BYTES */
    uint32_t        write_off;   /* bytes handed to lwIP so far */
    uint32_t        ack_off;     /* bytes acknowledged by the laptop */
    bool            complete;    /* set when done or failed */
    bool            connected;   /* handshake done; safe to tcp_write */
    bool            ok;          /* true only on full successful send */
} TCP_SEND_T;
 
static TCP_SEND_T sender;
 
/* Write as much of the remaining image as lwIP has room for, then flush. */
static void tcp_pump(TCP_SEND_T *s) {
    while (s->write_off < s->total) {
        u16_t avail = tcp_sndbuf(s->pcb);
        if (avail == 0) break;                 /* no room; wait for on_sent */
        uint32_t remaining = s->total - s->write_off;
        u16_t chunk = (remaining > avail) ? avail : (u16_t)remaining;
        if (chunk > TCP_MSS) chunk = TCP_MSS;
        err_t err = tcp_write(s->pcb, s->data + s->write_off, chunk,
                              TCP_WRITE_FLAG_COPY);
        if (err == ERR_OK) {
            s->write_off += chunk;
        } else if (err == ERR_MEM) {
            printf("tcp_write ERR_MEM avail=%u off=%lu\n", avail, s->write_off);
            break;                             /* temporarily full; wait */
        } else {
            printf("tcp_write err=%d\n", err);
            s->ok = false;                     /* real error */
            s->complete = true;
            return;
        }
    }
    tcp_output(s->pcb);                        /* push queued data onto the wire */
}
 
/* lwIP calls this when the laptop ACKs some bytes (space just freed). */
static err_t on_sent(void *arg, struct tcp_pcb *tpcb, u16_t len) {
    TCP_SEND_T *s = (TCP_SEND_T *)arg;
    s->ack_off += len;
    if (s->ack_off >= s->total) {
        s->ok = true;                          /* whole image acknowledged */
        s->complete = true;
    } else {
        tcp_pump(s);                           /* send more */
    }
    return ERR_OK;
}

/* lwIP calls this when the connection is established (or fails). */
static err_t on_connected(void *arg, struct tcp_pcb *tpcb, err_t err) {
    printf("on_connected err=%d\n", err);
    TCP_SEND_T *s = (TCP_SEND_T *)arg;
    if (err != ERR_OK) {
        s->ok = false;
        s->complete = true;
        return err;
    }
    s->connected = true;
    tcp_pump(s);                               /* start sending */                      /* start sending */
    return ERR_OK;
}
 
/* lwIP calls this on a connection error (pcb is already freed by lwIP). */
static void on_err(void *arg, err_t err) {
    TCP_SEND_T *s = (TCP_SEND_T *)arg;
    s->ok = false;
    s->complete = true;
    s->pcb = NULL;
}
 
/* Periodic poll — used here as a stall safety net. */
static err_t on_poll(void *arg, struct tcp_pcb *tpcb) {
    return ERR_OK;
}
 
/* Blocking send: connects, ships all of `data`, returns true on success.
 * Safe to call from your state machine; it spins until done (like your
 * spi_read16_blocking blocks). Assumes WiFi is already connected (see main). */
bool send_image_over_tcp(const uint8_t *data, uint32_t total) {
    sender.data       = data;
    sender.total      = total;
    sender.write_off  = 0;
    sender.ack_off    = 0;
    sender.complete   = false;
    sender.ok         = false;
    printf("send result: complete=%d ok=%d wrote=%lu acked=%lu\n",
       sender.complete, sender.ok, sender.write_off, sender.ack_off);
 
    if (!ip4addr_aton(LAPTOP_IP, &sender.remote_addr)) {
        printf("bad LAPTOP_IP\n");
        return false;
    }
 
    sender.pcb = tcp_new_ip_type(IPADDR_TYPE_V4);
    if (!sender.pcb) {
        printf("tcp_new failed\n");
        return false;
    }
    cyw43_arch_lwip_begin();
    tcp_arg(sender.pcb, &sender);
    tcp_sent(sender.pcb, on_sent);
    tcp_err(sender.pcb, on_err);
    tcp_poll(sender.pcb, on_poll, 10);         /* ~5 s poll interval */

    
    err_t err = tcp_connect(sender.pcb, &sender.remote_addr, TCP_PORT,
                            on_connected);
    cyw43_arch_lwip_end();
    if (err != ERR_OK) {
        printf("tcp_connect failed %d\n", err);
        return false;
    }
 
    /* Spin until the callbacks say we're done (threadsafe_background mode:
     * lwIP runs in the background, so a plain sleep loop is fine). 30 s cap. */
    uint32_t start = to_ms_since_boot(get_absolute_time());
    uint32_t last_print = start;
    while (!sender.complete) {
        cyw43_arch_lwip_begin();
        if (sender.pcb && sender.connected && sender.write_off < sender.total) {
            tcp_pump(&sender);
        }
        cyw43_arch_lwip_end();

        sleep_ms(10);

        uint32_t now = to_ms_since_boot(get_absolute_time());
        if (now - last_print > 1000) {              // progress, from FOREGROUND
            printf("progress: wrote=%lu acked=%lu\n",
                   sender.write_off, sender.ack_off);
            last_print = now;
        }
        if (now - start > 30000) { printf("tcp send timeout\n"); break; }
    }
 
    /* Tear down the connection. */
    cyw43_arch_lwip_begin();
    if (sender.pcb) {
        tcp_arg(sender.pcb, NULL);
        tcp_sent(sender.pcb, NULL);
        tcp_err(sender.pcb, NULL);
        tcp_poll(sender.pcb, NULL, 0);
        tcp_close(sender.pcb);
        sender.pcb = NULL;
    }
    cyw43_arch_lwip_end();
 
    return sender.ok;
}

enum states
{
    Init,
    SendingSignal,
    Receiving,
    WifiSend
} PicoStates;

uint8_t data = 0;
uint8_t* dataptr = &data;

uint16_t Storage[76800];

void Tick()
{
    switch (PicoStates)
    {
    case Init:
    if(!gpio_get(22)){
        printf("Init -> SendingSignal (gpio22=%d)\n", gpio_get(22));
        PicoStates = SendingSignal;
    }
    else {
        PicoStates = Init;
    }
        break; 
    case SendingSignal: 
    if(!gpio_get(22)) {
        printf("sending 0x01\n");
        gpio_put(17,0);
        data = 1;
        spi_set_format (spi0, 8, SPI_CPOL_0, SPI_CPHA_0, SPI_MSB_FIRST); //setting the format back to 8 bit 
        spi_write_blocking(spi0, dataptr, 1);
        gpio_put(17,1);
        PicoStates = Receiving;
    } else {
        PicoStates = Init;
    }
        break;

    case Receiving:
        spi_set_format (spi0, 16, SPI_CPOL_0, SPI_CPHA_0, SPI_MSB_FIRST);
        gpio_put(PIN_CS,0);
        spi_read16_blocking(spi0, 0, Storage, 76800);
        gpio_put(PIN_CS,1);
        printf("read done: px0=%04x px1=%04x px2=%04x\n", Storage[0], Storage[1], Storage[2]);
        uint32_t sum = 0;
        for (int i = 0; i < 76800; i++) sum += Storage[i];
        printf("read done: px0=%04x px1=%04x px2=%04x sum=%lu last=%04x\n",
               Storage[0], Storage[1], Storage[2], sum, Storage[76799]);
        PicoStates = WifiSend;
        break;
    case WifiSend:
        bool ok = send_image_over_tcp((const uint8_t *)Storage, IMAGE_BYTES);
        printf("wifi send %s\n", ok ? "OK" : "FAILED");
        PicoStates = Init;
        break;
    default:
    PicoStates = Init;
        break;
    }

    switch (PicoStates)
    {
    case Init:
        break;
    case SendingSignal:
        break;
    case Receiving:
        break;
    case WifiSend:
        break;
    default:
        break;
    }
}


int main()
{
    stdio_init_all();
    sleep_ms(2000);
    PicoStates = Init;

    if (cyw43_arch_init()) {
    printf("Wi-Fi init failed\n");
    return -1;
    }
    // Initialise the Wi-Fi chip
    cyw43_arch_enable_sta_mode();
    printf("Connecting to Wi-Fi...\n");
      int rc;
      do {
          printf("Connecting to Wi-Fi...\n");
          rc = cyw43_arch_wifi_connect_timeout_ms(
                  WIFI_SSID, WIFI_PASSWORD,
                  CYW43_AUTH_WPA2_AES_PSK, 30000);
          printf("wifi connect rc=%d\n", rc);
          if (rc != 0) sleep_ms(1000);   // brief pause, then try again
      } while (rc != 0);
      printf("Connected.\n");
    // SPI initialisation. This example will use SPI at 1MHz.
    spi_init(SPI_PORT, 1000 * 1000);
    gpio_set_function(PIN_MISO, GPIO_FUNC_SPI);
    gpio_set_function(PIN_CS, GPIO_FUNC_SIO);
    gpio_set_function(PIN_SCK, GPIO_FUNC_SPI);
    gpio_set_function(PIN_MOSI, GPIO_FUNC_SPI);


    // Chip select is active-low, so we'll initialise it to a driven-high state
    gpio_set_dir(PIN_CS, GPIO_OUT);
    gpio_put(PIN_CS, 1);

    gpio_init(22); 
    gpio_set_dir(22, false); // button/ultrasonic Sensor input
    gpio_pull_up(22);


    // For more examples of SPI use see https://github.com/raspberrypi/pico-examples/tree/master/spi

    // I2C Initialisation. Using it at 400Khz.
    // i2c_init(I2C_PORT, 400*1000);

    // gpio_set_function(I2C_SDA, GPIO_FUNC_I2C);
    // gpio_set_function(I2C_SCL, GPIO_FUNC_I2C);
    // gpio_pull_up(I2C_SDA);
    // gpio_pull_up(I2C_SCL);
    // For more examples of I2C use see https://github.com/raspberrypi/pico-examples/tree/master/i2c

    // Get a free channel, panic() if there are none
    // int chan = dma_claim_unused_channel(true);

    // 8 bit transfers. Both read and write address increment after each
    // transfer (each pointing to a location in src or dst respectively).
    // No DREQ is selected, so the DMA transfers as fast as it can.

    // dma_channel_config c = dma_channel_get_default_config(chan);
    // channel_config_set_transfer_data_size(&c, DMA_SIZE_8);
    // channel_config_set_read_increment(&c, true);
    // channel_config_set_write_increment(&c, true);

    // dma_channel_configure(
    //     chan,          // Channel to be configured
    //     &c,            // The configuration we just created
    //     dst,           // The initial write address
    //     src,           // The initial read address
    //     count_of(src), // Number of transfers; in this case each is 1 byte.
    //     true           // Start immediately.
    // );

    // We could choose to go and do something else whilst the DMA is doing its
    // thing. In this case the processor has nothing else to do, so we just
    // wait for the DMA to finish.
    // dma_channel_wait_for_finish_blocking(chan);

    // The DMA has now copied our text from the transmit buffer (src) to the
    // receive buffer (dst), so we can print it out from there.
    // puts(dst);
    // Data will be copied from src to dst
    // const char src[] = "Hello, world! (from DMA)";
    // char dst[count_of(src)];

    // int64_t alarm_callback(alarm_id_t id, void *user_data) {
    //     // Put your timeout handler code in here
    //     return 0;
    // }


    while (true)
    {   
        #if PICO_CYW43_ARCH_POLL
        cyw43_arch_poll();
        #endif
        // printf("Hello, world!\n");
        printf("gpio22=%d state=%d link=%d ip=%s\n", gpio_get(22), PicoStates,
         cyw43_tcpip_link_status(&cyw43_state, CYW43_ITF_STA),
         ip4addr_ntoa(netif_ip4_addr(netif_default)));
        sleep_ms(200);
        Tick();
    }
}
