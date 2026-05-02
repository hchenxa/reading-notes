# Appium

## 安装配置

### 基础依赖

- java

```bash
hchenxa@huichen1-mac reading-notes % brew search openjdk
hchenxa@huichen1-mac reading-notes % brew install openjdk@17
hchenxa@huichen1-mac ~ % /usr/libexec/java_home
/opt/homebrew/Cellar/openjdk@17/17.0.19/libexec/openjdk.jdk/Contents/Home
hchenxa@huichen1-mac ~ % export JAVA_HOME=/opt/homebrew/Cellar/openjdk@17/17.0.19/libexec/openjdk.jdk/Contents/Home
hchenxa@huichen1-mac ~ % export PATH=$PATH:$JAVA_HOME
```

- nodejs

```bash
hchenxa@huichen1-mac reading-notes % brew search node
hchenxa@huichen1-mac reading-notes % brew install node
```

### 核心驱动

- appium

```bash
hchenxa@huichen1-mac reading-notes % npm install -g appium
```

### 平台驱动安装

- Android驱动

```bash
appium driver install uiautomator2
```

- iOS驱动

```bash
appium driver install xcuitest
```

### 安装 Appium Inspector（用于定位页面元素的桌面客户端）


### 安装缺失的组建

```bash
hchenxa@huichen1-mac latest % export ANDROID_HOME=$HOME/Library/Android/sdk
hchenxa@huichen1-mac latest % export PATH=$PATH:$ANDROID_HOME/emulator
hchenxa@huichen1-mac latest % export PATH=$PATH:$ANDROID_HOME/platform-tools
hchenxa@huichen1-mac latest % export PATH=$PATH:$ANDROID_HOME/tools
hchenxa@huichen1-mac latest % sdkmanager --licenses 
hchenxa@huichen1-mac latest % sdkmanager "platform-tools" "emulator" "tools"
```

MacOS上有时候会安装到Downloads目录下，可以手动拷贝到或者配置一下环境变量


## 安装Python client

```bash
pip install Appium-Python-Client==2.11.1
```

**NOTE：2.X的版本和3.X的版本的差别比较大**

## 在macOS上启动模拟器

```bash
sdkmanager --list | grep system-images #用来list出一下安卓系统镜像。对于 M 芯片的 Mac，建议找带有 android-33（即 Android 13）或更高版本，且架构为 arm64-v8a 的镜像
```

```bash
sdkmanager "system-images;android-33;google_apis;arm64-v8a" #使用sdkmanager下载对应的image
```

```bash
avdmanager create avd -n Pixel_7_API_33 -k "system-images;android-33;google_apis;arm64-v8a" #创建虚拟设备
```

```bash
emulator -list-avds #执行emulator list查看设备
```

```bash
emulator -avd Pixel_7_API_33 #启动设备
```

```bash
emulator -avd Pixel_7_API_33 -wipe-data #可以用来重制设备。
```

### adb使用

可以使用adb命令查看当前设备信息

```bash
hchenxa@huichen1-mac ~ % adb devices
List of devices attached
emulator-5554	device
```

实时抓取当前操作

```bash
adb shell dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'
adb shell dumpsys window windows | grep -E 'mFocusedApp'
```

获取版本号

```bash
adb shell getprop ro.build.version.release
```