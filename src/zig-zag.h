#pragma once
#include <stdbool.h>
#include <stdint.h>

bool startServer(void);
void stopServer(void);
bool isServerRunning(void);
uint16_t getServerPort(void);
