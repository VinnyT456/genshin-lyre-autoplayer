CXX = clang++
CXXFLAGS = -std=c++20 -g -Wall -fobjc-arc
LDFLAGS =
FRAMEWORKS = -framework Foundation -framework AppKit -framework CoreGraphics \
	-framework ApplicationServices -framework UniformTypeIdentifiers \
	-framework QuartzCore

BUILD_DIR = build
TARGET = $(BUILD_DIR)/macauto.out
SRC = src/main.mm \
	src/ui/PlayerWindow.mm src/ui/practice_dashboard.mm \
	src/ui/note_highway.mm src/ui/key_overlay.mm \
	src/ui/key_layout.mm src/ui/key_calibration.mm src/ui/settings_window.mm src/ui/song_library.mm \
	src/ui/theme.mm src/ui/strings.mm \
	src/app/keyboard.mm src/app/genshin.mm src/app/settings.cpp \
	src/playback/parser.cpp src/playback/playback_controller.cpp

NLOHMANN_INCLUDE ?= $(firstword $(wildcard /opt/homebrew/include /usr/local/include))
INCLUDES = -Isrc -Isrc/app -Isrc/playback -Isrc/ui
ifneq ($(NLOHMANN_INCLUDE),)
INCLUDES += -I$(NLOHMANN_INCLUDE)
endif

.PHONY: all build run clean

all: build

build:
	mkdir -p $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $(INCLUDES) $(SRC) -o $(TARGET) $(FRAMEWORKS) $(LDFLAGS)

# make run                              # HUD, open songs from UI
# make run SHEET="path/to/song.genshinsheet"
# make run SHEET="path/to/song.mid"
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
