CXX = clang++
CXXFLAGS = -std=c++20 -g -Wall -fobjc-arc
LDFLAGS =
FRAMEWORKS = -framework Foundation -framework AppKit -framework CoreGraphics \
	-framework ApplicationServices -framework UniformTypeIdentifiers

TARGET = macauto.out
SRC = src/main.mm src/PlayerWindow.mm src/keyboard.mm src/genshin.mm \
	src/parser.cpp src/playback_controller.cpp src/settings.cpp

NLOHMANN_INCLUDE ?= $(firstword $(wildcard /opt/homebrew/include /usr/local/include))
ifneq ($(NLOHMANN_INCLUDE),)
INCLUDES = -I$(NLOHMANN_INCLUDE)
endif

.PHONY: all build run clean

all: build

build:
	$(CXX) $(CXXFLAGS) $(INCLUDES) $(SRC) -o $(TARGET) $(FRAMEWORKS) $(LDFLAGS)

# make run                              # HUD, open songs from UI
# make run SHEET="path/to/song.genshinsheet"
# make run SHEET="path/to/song.genshinsheet" NO_HUD=1
run:
ifdef NO_HUD
ifndef SHEET
	@echo "Usage: make run SHEET=path/to/song.genshinsheet NO_HUD=1"
	@exit 1
endif
	./$(TARGET) --no-hud "$(SHEET)"
else
ifdef SHEET
	./$(TARGET) "$(SHEET)"
else
	./$(TARGET)
endif
endif

clean:
	rm -f $(TARGET)
	rm -rf $(TARGET).dSYM
