#!/bin/bash

function print_help() {
    echo "将真机 arm64 架构的二进制转换为模拟器 arm64"
    echo ""
    echo "Notice:"
    echo "  支持转换动态库和静态库, 支持 .framework 和 .a"
    echo "  输出 xcframework 格式"
    echo ""
    echo "Usage:"
    echo "  bash path/to/xcframework_generator.sh 'path/to/binary'"
    echo ""
    echo "Example:"
    echo "  bash path/to/xcframework_generator.sh '/tmp/AliPlayerSDK_iOS/alivcffmpeg.framework/alivcffmpeg'"
    echo "  bash path/to/xcframework_generator.sh '/tmp/AFNetworking.framework/Versions/A/AFNetworking'"
    echo "  bash path/to/xcframework_generator.sh '/tmp/Masonry/libMasonry.a'"
    echo ""
}

set -x
INPUT_BINARY_PATH=${1:-"/tmp/Masonry/libMasonry.a"}
TMP_DIR=$(mktemp -d)
set +x

function generate_static_arm64() {
    NAKED_NAME="$1"
    CURRENT_SCRIPT_DIR=$(dirname "$0")
    arm64_to_sim="$CURRENT_SCRIPT_DIR"/arm64-to-sim/.build/apple/Products/Release/arm64-to-sim

    # Step-2.2: 从瘦二进制提取 .o 文件
    ar x "../$NAKED_NAME.arm64"

    # Step-2.3: 修改 .o 文件
    # see https://bogo.wtf/arm64-to-sim.html
    for file in *.o
    do 
        "$arm64_to_sim" $file 
    done

    # Step-2.4: 聚合 .o 生成新的瘦二进制
    ar crv "../$NAKED_NAME.arm64-reworked" *.o
}

function generate_dynamic_arm64() {
    NAKED_NAME="$1"

    # see https://bogo.wtf/arm64-to-sim-dylibs.html
    xcrun vtool "$NAKED_NAME.arm64" \
                -arch arm64 \
                -set-build-version 7 13.0 13.0 \
                -replace \
                -output "$NAKED_NAME.arm64-reworked"
}

function process_framework() {
    set -x
    RELATIVE_PATH=${INPUT_BINARY_PATH#*.framework/}
    INPUT_FRAMEWORK_PATH=${INPUT_BINARY_PATH%/"$RELATIVE_PATH"}
    NAKED_NAME=$(basename "$RELATIVE_PATH")
    FRAMEWORK_NAME=$(basename "$INPUT_FRAMEWORK_PATH")
    # set +x

    IOS_FRAMEWORK_PATH="$TMP_DIR/iOS/$FRAMEWORK_NAME"
    SIM_FRAMEWORK_PATH="$TMP_DIR/sim/$FRAMEWORK_NAME"
    mkdir -p "$TMP_DIR"/iOS
    mkdir -p "$TMP_DIR"/sim

    # Step-0: 准备胖二进制
    ORIGIN_BINARY_PATH="$TMP_DIR/$NAKED_NAME".origin
    cp "$INPUT_BINARY_PATH" "$ORIGIN_BINARY_PATH"

    # Step-1: 处理真机二进制
    cp -a "$INPUT_FRAMEWORK_PATH" "$IOS_FRAMEWORK_PATH"
    lipo "$ORIGIN_BINARY_PATH" \
         -extract arm64 \
         -output "$IOS_FRAMEWORK_PATH/$RELATIVE_PATH"

    # Step-2: 处理模拟器 arm64 二进制
    cp -a "$INPUT_FRAMEWORK_PATH" "$SIM_FRAMEWORK_PATH"

    # Step-2.1: 提取瘦二进制
    lipo "$ORIGIN_BINARY_PATH" -thin arm64 -output "$TMP_DIR/$NAKED_NAME.arm64"
    if lipo "$ORIGIN_BINARY_PATH" -thin x86_64 -output "$TMP_DIR/$NAKED_NAME.x86_64"
    then
        X86_PATH="$TMP_DIR/$NAKED_NAME.x86_64"
    fi

    if file -b "$INPUT_BINARY_PATH" | grep -q 'dynamically linked'
    then
        cd "$TMP_DIR"
            generate_dynamic_arm64 "$NAKED_NAME"
        cd -
    elif file -b "$INPUT_BINARY_PATH" | grep -q 'current ar archive'
    then
        mkdir -p "$TMP_DIR/$NAKED_NAME-reworked"
        cd "$TMP_DIR/$NAKED_NAME-reworked"
            generate_static_arm64 "$NAKED_NAME"
        cd -
    fi

    # Step-2.5: 生成新的胖二进制
    lipo -create "$TMP_DIR/$NAKED_NAME.arm64-reworked" $X86_PATH \
         -output "$SIM_FRAMEWORK_PATH/$RELATIVE_PATH"

    # Step-3: 制作 XCFramework
    XCFRAMEWORK_PATH="$NAKED_NAME.xcframework"
    xcodebuild -create-xcframework \
               -framework "$SIM_FRAMEWORK_PATH" \
               -framework "$IOS_FRAMEWORK_PATH" \
               -output "$XCFRAMEWORK_PATH"

    if file -b "$INPUT_BINARY_PATH" | grep -q 'dynamically linked'
    then
        # 动态库签名
        for path in "$XCFRAMEWORK_PATH"/**/*.framework
        do
            framework_path="$path/$RELATIVE_PATH"
            echo "sign $framework_path"
            xcrun codesign --sign - "$framework_path"
        done
    fi

    # Step-4: 清理
    rm -rf "$TMP_DIR"
}

function process_library() {
    set -x
    RELATIVE_PATH=$(basename "$INPUT_BINARY_PATH")
    INPUT_FRAMEWORK_PATH=${INPUT_BINARY_PATH%/"$RELATIVE_PATH"}
    NAKED_NAME=$(basename "$RELATIVE_PATH" | sed 's/^\(.\{1,\}\)\(\.a\{0,1\}\)$/\1/g')
    FRAMEWORK_NAME=$(basename "$INPUT_FRAMEWORK_PATH")
    OUTPUT_XCFRAMEWORK_PATH="$NAKED_NAME".xcframework
    # set +x

    IOS_FRAMEWORK_PATH="$TMP_DIR/iOS/$NAKED_NAME".a
    SIM_FRAMEWORK_PATH="$TMP_DIR/sim/$NAKED_NAME".a
    mkdir -p "$TMP_DIR"/sim
    mkdir -p "$TMP_DIR"/iOS

    # Step-0: 准备胖二进制
    ORIGIN_BINARY_PATH="$TMP_DIR/$NAKED_NAME".origin
    cp "$INPUT_BINARY_PATH" "$ORIGIN_BINARY_PATH"

    function process_thin() {
        cp "$ORIGIN_BINARY_PATH" "$TMP_DIR/$NAKED_NAME.arm64"
        mkdir -p "$TMP_DIR/$NAKED_NAME-reworked"
        cd "$TMP_DIR/$NAKED_NAME-reworked"
            generate_static_arm64 "$NAKED_NAME"
        cd -

        # Step-2.5: 生成新的模拟器二进制
        lipo -create "$TMP_DIR/$NAKED_NAME.arm64-reworked" \
             -output "$SIM_FRAMEWORK_PATH"
        
        # Step-1: 处理真机二进制
        lipo -create "$TMP_DIR/$NAKED_NAME.arm64" \
             -output "$IOS_FRAMEWORK_PATH"
    }

    function process_fat() {
        # Step-2: 处理模拟器 arm64 二进制
        lipo "$ORIGIN_BINARY_PATH" -thin arm64 -output "$TMP_DIR/$NAKED_NAME.arm64"
        if lipo "$ORIGIN_BINARY_PATH" -thin x86_64 -output "$TMP_DIR/$NAKED_NAME.x86_64"
        then
            X86_PATH="$TMP_DIR/$NAKED_NAME.x86_64"
        fi

        mkdir -p "$TMP_DIR/$NAKED_NAME-reworked"
        cd "$TMP_DIR/$NAKED_NAME-reworked"
            generate_static_arm64 "$NAKED_NAME"
        cd -

        # Step-2.5: 生成新的胖二进制
        lipo -create "$TMP_DIR/$NAKED_NAME.arm64-reworked" $X86_PATH \
             -output "$SIM_FRAMEWORK_PATH"

        # Step-1: 处理真机二进制
        lipo "$ORIGIN_BINARY_PATH" \
             -extract arm64 \
             -output "$IOS_FRAMEWORK_PATH"
    }

    if lipo -info "$ORIGIN_BINARY_PATH" | grep -q "Non-fat.*arm64"
    then
        # 处理 arm64 瘦二进制, 特殊情况
        process_thin
    else
        # 处理胖二进制, 一般情况
        process_fat
    fi

    # Step-3: 制作 XCFramework
    # if find "$INPUT_FRAMEWORK_PATH" -name '*.h' -maxdepth 1 | grep -q '.h'
    # then
    #     xcodebuild -create-xcframework \
    #                -library "$IOS_FRAMEWORK_PATH" -headers $(find "$INPUT_FRAMEWORK_PATH" -name '*.h' -maxdepth 1) \
    #                -library "$SIM_FRAMEWORK_PATH" -headers $(find "$INPUT_FRAMEWORK_PATH" -name '*.h' -maxdepth 1) \
    #                -output "$OUTPUT_XCFRAMEWORK_PATH"
    # else
        xcodebuild -create-xcframework \
                   -library "$IOS_FRAMEWORK_PATH" \
                   -library "$SIM_FRAMEWORK_PATH" \
                   -output "$OUTPUT_XCFRAMEWORK_PATH"
    # fi
    

    # Step-4: 清理
    rm -rf "$TMP_DIR"
}

if echo "$INPUT_BINARY_PATH" | grep -q '\.a$'
then
    echo "processing static library"
    process_library
elif echo "$INPUT_BINARY_PATH" | grep -q '\.framework'
then
    if file -b "$INPUT_BINARY_PATH" | grep -q 'dynamically linked'
    then
        echo "processing dynamic framework"
        process_framework
    elif file -b "$INPUT_BINARY_PATH" | grep -q 'current ar archive'
    then
        echo "processing static framework"
        process_framework
    fi
fi
