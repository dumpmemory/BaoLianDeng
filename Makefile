# Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

RUST_FFI_DIR = Rust/mihomo-ffi
FFI_OBJC = $(RUST_FFI_DIR)/objc
FRAMEWORK_DIR = Framework
FRAMEWORK_NAME = MihomoCore
BUILD_DIR = /tmp/mihomo-ffi-build

# Rust build flags for iOS
CARGO_FLAGS = --release
RUSTFLAGS_IOS = -C strip=symbols

# iOS SDK paths
IOS_SDK = $(shell xcrun --sdk iphoneos --show-sdk-path)
SIM_SDK = $(shell xcrun --sdk iphonesimulator --show-sdk-path)

# macOS SDK path
MACOS_SDK = $(shell xcrun --sdk macosx --show-sdk-path)

# Rust build flags for macOS (same strip setting as iOS)
RUSTFLAGS_MACOS = -C strip=symbols

.PHONY: all framework framework-arm64 framework-macos framework-all clean

all: framework

framework:
	# Build Rust staticlib for each target
	cd $(RUST_FFI_DIR) && RUSTFLAGS="$(RUSTFLAGS_IOS)" cargo build $(CARGO_FLAGS) --target aarch64-apple-ios
	cd $(RUST_FFI_DIR) && RUSTFLAGS="$(RUSTFLAGS_IOS)" cargo build $(CARGO_FLAGS) --target aarch64-apple-ios-sim
	cd $(RUST_FFI_DIR) && RUSTFLAGS="$(RUSTFLAGS_IOS)" cargo build $(CARGO_FLAGS) --target x86_64-apple-ios
	# Compile ObjC wrapper for each arch
	@mkdir -p $(BUILD_DIR)
	xcrun clang -c $(FFI_OBJC)/MihomoCore.m -o $(BUILD_DIR)/objc-device.o \
		-target arm64-apple-ios17.0 -fobjc-arc -isysroot $(IOS_SDK) -I$(FFI_OBJC)
	xcrun clang -c $(FFI_OBJC)/MihomoCore.m -o $(BUILD_DIR)/objc-sim-arm64.o \
		-target arm64-apple-ios17.0-simulator -fobjc-arc -isysroot $(SIM_SDK) -I$(FFI_OBJC)
	xcrun clang -c $(FFI_OBJC)/MihomoCore.m -o $(BUILD_DIR)/objc-sim-x86.o \
		-target x86_64-apple-ios17.0-simulator -fobjc-arc -isysroot $(SIM_SDK) -I$(FFI_OBJC)
	# Combine Rust .a + ObjC .o into single .a per target
	@mkdir -p $(BUILD_DIR)/device $(BUILD_DIR)/sim
	xcrun libtool -static -o $(BUILD_DIR)/device/lib$(FRAMEWORK_NAME).a \
		$(RUST_FFI_DIR)/target/aarch64-apple-ios/release/libmihomo_ffi.a $(BUILD_DIR)/objc-device.o
	xcrun libtool -static -o $(BUILD_DIR)/sim-arm64.a \
		$(RUST_FFI_DIR)/target/aarch64-apple-ios-sim/release/libmihomo_ffi.a $(BUILD_DIR)/objc-sim-arm64.o
	xcrun libtool -static -o $(BUILD_DIR)/sim-x86.a \
		$(RUST_FFI_DIR)/target/x86_64-apple-ios/release/libmihomo_ffi.a $(BUILD_DIR)/objc-sim-x86.o
	# Fat library for simulator (arm64 + x86_64)
	lipo -create $(BUILD_DIR)/sim-arm64.a $(BUILD_DIR)/sim-x86.a \
		-output $(BUILD_DIR)/sim/lib$(FRAMEWORK_NAME).a
	# Prepare headers directory (only .h and modulemap, no .m)
	@rm -rf $(BUILD_DIR)/headers
	@mkdir -p $(BUILD_DIR)/headers
	@cp $(FFI_OBJC)/MihomoCore.h $(BUILD_DIR)/headers/
	@cp $(FFI_OBJC)/module.modulemap $(BUILD_DIR)/headers/
	# Create xcframework
	rm -rf $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework
	xcodebuild -create-xcframework \
		-library $(BUILD_DIR)/device/lib$(FRAMEWORK_NAME).a -headers $(BUILD_DIR)/headers \
		-library $(BUILD_DIR)/sim/lib$(FRAMEWORK_NAME).a -headers $(BUILD_DIR)/headers \
		-output $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework
	@echo "Built $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework"

framework-arm64:
	cd $(RUST_FFI_DIR) && RUSTFLAGS="$(RUSTFLAGS_IOS)" cargo build $(CARGO_FLAGS) --target aarch64-apple-ios
	@mkdir -p $(BUILD_DIR)
	xcrun clang -c $(FFI_OBJC)/MihomoCore.m -o $(BUILD_DIR)/objc-device.o \
		-target arm64-apple-ios17.0 -fobjc-arc -isysroot $(IOS_SDK) -I$(FFI_OBJC)
	@mkdir -p $(BUILD_DIR)/device
	xcrun libtool -static -o $(BUILD_DIR)/device/lib$(FRAMEWORK_NAME).a \
		$(RUST_FFI_DIR)/target/aarch64-apple-ios/release/libmihomo_ffi.a $(BUILD_DIR)/objc-device.o
	@rm -rf $(BUILD_DIR)/headers
	@mkdir -p $(BUILD_DIR)/headers
	@cp $(FFI_OBJC)/MihomoCore.h $(BUILD_DIR)/headers/
	@cp $(FFI_OBJC)/module.modulemap $(BUILD_DIR)/headers/
	rm -rf $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework
	xcodebuild -create-xcframework \
		-library $(BUILD_DIR)/device/lib$(FRAMEWORK_NAME).a -headers $(BUILD_DIR)/headers \
		-output $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework
	@echo "Built $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework (arm64 only)"

framework-macos:
	# Build Rust staticlib for each macOS target
	cd $(RUST_FFI_DIR) && RUSTFLAGS="$(RUSTFLAGS_MACOS)" cargo build $(CARGO_FLAGS) --target aarch64-apple-darwin
	cd $(RUST_FFI_DIR) && RUSTFLAGS="$(RUSTFLAGS_MACOS)" cargo build $(CARGO_FLAGS) --target x86_64-apple-darwin
	# Compile ObjC wrapper for each macOS arch
	@mkdir -p $(BUILD_DIR)
	xcrun clang -c $(FFI_OBJC)/MihomoCore.m -o $(BUILD_DIR)/objc-macos-arm64.o \
		-target arm64-apple-macos14.0 -fobjc-arc -isysroot $(MACOS_SDK) -I$(FFI_OBJC)
	xcrun clang -c $(FFI_OBJC)/MihomoCore.m -o $(BUILD_DIR)/objc-macos-x86.o \
		-target x86_64-apple-macos14.0 -fobjc-arc -isysroot $(MACOS_SDK) -I$(FFI_OBJC)
	# Combine Rust .a + ObjC .o into single .a per arch
	xcrun libtool -static -o $(BUILD_DIR)/macos-arm64.a \
		$(RUST_FFI_DIR)/target/aarch64-apple-darwin/release/libmihomo_ffi.a $(BUILD_DIR)/objc-macos-arm64.o
	xcrun libtool -static -o $(BUILD_DIR)/macos-x86.a \
		$(RUST_FFI_DIR)/target/x86_64-apple-darwin/release/libmihomo_ffi.a $(BUILD_DIR)/objc-macos-x86.o
	# Fat library for macOS (arm64 + x86_64)
	@mkdir -p $(BUILD_DIR)/macos
	lipo -create $(BUILD_DIR)/macos-arm64.a $(BUILD_DIR)/macos-x86.a \
		-output $(BUILD_DIR)/macos/lib$(FRAMEWORK_NAME).a
	# Prepare headers directory
	@rm -rf $(BUILD_DIR)/headers
	@mkdir -p $(BUILD_DIR)/headers
	@cp $(FFI_OBJC)/MihomoCore.h $(BUILD_DIR)/headers/
	@cp $(FFI_OBJC)/module.modulemap $(BUILD_DIR)/headers/
	# Create xcframework (macOS only)
	rm -rf $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework
	xcodebuild -create-xcframework \
		-library $(BUILD_DIR)/macos/lib$(FRAMEWORK_NAME).a -headers $(BUILD_DIR)/headers \
		-output $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework
	@echo "Built $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework (macOS arm64+x86_64)"

framework-all:
	# Build Rust staticlib for all targets (iOS device, iOS simulator, macOS)
	cd $(RUST_FFI_DIR) && RUSTFLAGS="$(RUSTFLAGS_IOS)" cargo build $(CARGO_FLAGS) --target aarch64-apple-ios
	cd $(RUST_FFI_DIR) && RUSTFLAGS="$(RUSTFLAGS_IOS)" cargo build $(CARGO_FLAGS) --target aarch64-apple-ios-sim
	cd $(RUST_FFI_DIR) && RUSTFLAGS="$(RUSTFLAGS_IOS)" cargo build $(CARGO_FLAGS) --target x86_64-apple-ios
	cd $(RUST_FFI_DIR) && RUSTFLAGS="$(RUSTFLAGS_MACOS)" cargo build $(CARGO_FLAGS) --target aarch64-apple-darwin
	cd $(RUST_FFI_DIR) && RUSTFLAGS="$(RUSTFLAGS_MACOS)" cargo build $(CARGO_FLAGS) --target x86_64-apple-darwin
	# Compile ObjC wrapper for all arches
	@mkdir -p $(BUILD_DIR)
	xcrun clang -c $(FFI_OBJC)/MihomoCore.m -o $(BUILD_DIR)/objc-device.o \
		-target arm64-apple-ios17.0 -fobjc-arc -isysroot $(IOS_SDK) -I$(FFI_OBJC)
	xcrun clang -c $(FFI_OBJC)/MihomoCore.m -o $(BUILD_DIR)/objc-sim-arm64.o \
		-target arm64-apple-ios17.0-simulator -fobjc-arc -isysroot $(SIM_SDK) -I$(FFI_OBJC)
	xcrun clang -c $(FFI_OBJC)/MihomoCore.m -o $(BUILD_DIR)/objc-sim-x86.o \
		-target x86_64-apple-ios17.0-simulator -fobjc-arc -isysroot $(SIM_SDK) -I$(FFI_OBJC)
	xcrun clang -c $(FFI_OBJC)/MihomoCore.m -o $(BUILD_DIR)/objc-macos-arm64.o \
		-target arm64-apple-macos14.0 -fobjc-arc -isysroot $(MACOS_SDK) -I$(FFI_OBJC)
	xcrun clang -c $(FFI_OBJC)/MihomoCore.m -o $(BUILD_DIR)/objc-macos-x86.o \
		-target x86_64-apple-macos14.0 -fobjc-arc -isysroot $(MACOS_SDK) -I$(FFI_OBJC)
	# Combine Rust .a + ObjC .o into single .a per target
	@mkdir -p $(BUILD_DIR)/device $(BUILD_DIR)/sim $(BUILD_DIR)/macos
	xcrun libtool -static -o $(BUILD_DIR)/device/lib$(FRAMEWORK_NAME).a \
		$(RUST_FFI_DIR)/target/aarch64-apple-ios/release/libmihomo_ffi.a $(BUILD_DIR)/objc-device.o
	xcrun libtool -static -o $(BUILD_DIR)/sim-arm64.a \
		$(RUST_FFI_DIR)/target/aarch64-apple-ios-sim/release/libmihomo_ffi.a $(BUILD_DIR)/objc-sim-arm64.o
	xcrun libtool -static -o $(BUILD_DIR)/sim-x86.a \
		$(RUST_FFI_DIR)/target/x86_64-apple-ios/release/libmihomo_ffi.a $(BUILD_DIR)/objc-sim-x86.o
	xcrun libtool -static -o $(BUILD_DIR)/macos-arm64.a \
		$(RUST_FFI_DIR)/target/aarch64-apple-darwin/release/libmihomo_ffi.a $(BUILD_DIR)/objc-macos-arm64.o
	xcrun libtool -static -o $(BUILD_DIR)/macos-x86.a \
		$(RUST_FFI_DIR)/target/x86_64-apple-darwin/release/libmihomo_ffi.a $(BUILD_DIR)/objc-macos-x86.o
	# Fat libraries for simulator and macOS
	lipo -create $(BUILD_DIR)/sim-arm64.a $(BUILD_DIR)/sim-x86.a \
		-output $(BUILD_DIR)/sim/lib$(FRAMEWORK_NAME).a
	lipo -create $(BUILD_DIR)/macos-arm64.a $(BUILD_DIR)/macos-x86.a \
		-output $(BUILD_DIR)/macos/lib$(FRAMEWORK_NAME).a
	# Prepare headers directory
	@rm -rf $(BUILD_DIR)/headers
	@mkdir -p $(BUILD_DIR)/headers
	@cp $(FFI_OBJC)/MihomoCore.h $(BUILD_DIR)/headers/
	@cp $(FFI_OBJC)/module.modulemap $(BUILD_DIR)/headers/
	# Create xcframework with all slices (ios-arm64, ios-arm64_x86_64-simulator, macos-arm64_x86_64)
	rm -rf $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework
	xcodebuild -create-xcframework \
		-library $(BUILD_DIR)/device/lib$(FRAMEWORK_NAME).a -headers $(BUILD_DIR)/headers \
		-library $(BUILD_DIR)/sim/lib$(FRAMEWORK_NAME).a -headers $(BUILD_DIR)/headers \
		-library $(BUILD_DIR)/macos/lib$(FRAMEWORK_NAME).a -headers $(BUILD_DIR)/headers \
		-output $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework
	@echo "Built $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework (iOS + macOS, all slices)"

clean:
	rm -rf $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework
	rm -rf $(BUILD_DIR)
	cd $(RUST_FFI_DIR) && cargo clean
