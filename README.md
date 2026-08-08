# FPGA Camera and Image-Processing System

Course project integrating an OV7670 camera, an iCESugar Pro ECP5 FPGA, SDRAM, a TFT display, a Raspberry Pi Pico 2 W, and a laptop receiver. The system captures 320 x 240 RGB565 frames, applies selectable pixel transformations, displays the result, and can stream a 153,600-byte frame over Wi-Fi to a Python receiver.

![Captured frame](laptopRecevier/frame.png)

## System flow

```text
OV7670 camera -> FPGA capture/configuration -> SDRAM frame buffer
                                           |-> TFT display
                                           |-> SPI -> Pico 2 W -> TCP -> laptop receiver
```

## Repository layout

- `CustomProject-FPGA/`: SystemVerilog camera, SDRAM, clock-domain crossing, image-processing, display, and SPI integration.
- `CustomProject-PICO/`: Pico SDK C application that reads an RGB565 frame over SPI and sends it with lwIP/TCP.
- `laptopRecevier/`: Python receiver that saves the raw frame and optionally converts RGB565 data to PNG with Pillow.
- `hyang243_custom_lab_report.pdf`: course report with design notes, debugging observations, and source acknowledgements.

## Hardware and tools

- iCESugar Pro FPGA board with Lattice ECP5 and SDRAM
- OV7670 camera and TFT display
- Raspberry Pi Pico 2 W
- SystemVerilog, C, and Python
- Yosys, nextpnr-ecp5, Icarus Verilog, Pico SDK, CMake, and lwIP

## Local Wi-Fi configuration

Credentials are never committed. Create a local configuration before building the Pico firmware:

```sh
cp CustomProject-PICO/wifi_config.h.example CustomProject-PICO/wifi_config.h
```

Edit `wifi_config.h` with the Wi-Fi network, password, and laptop IP address. The real file is excluded by `.gitignore`.

## Build and run

FPGA toolchain:

```sh
mkdir -p CustomProject-FPGA/build
make -C CustomProject-FPGA top.bit
```

Pico firmware:

```sh
cmake -S CustomProject-PICO -B CustomProject-PICO/build
cmake --build CustomProject-PICO/build
```

Laptop receiver:

```sh
cd laptopRecevier
python3 receiver.py
```

Pillow is optional and is used only for PNG conversion.

## Project scope and provenance

This repository contains a mixture of course/reference RTL and project-specific integration. The project work focused on connecting the camera, memory, display, FPGA/Pico SPI path, image transformations, TCP frame transfer, and physical-system validation. Camera configuration and SPI references are acknowledged in the included report. AI tools were used as a tutor and debugging assistant; reference-assisted components are described as adapted or integrated rather than independently authored.

## Current limitations

- Wi-Fi and receiver configuration is compile-time and local to each device.
- The transfer sends one complete RGB565 frame rather than continuous video.
- The repository does not yet claim RTOS, CAN, LVGL, TinyML, or autonomous-driving functionality.

