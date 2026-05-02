from time import sleep

from appium import webdriver

# from appium.options.android import UiAutomator2Options
# from appium.webdriver.common.appiumby import AppiumBy

# below configuration is for client v3 version
# options = UiAutomator2Options()
# options.platform_name = 'Android'
# options.device_name = 'Pixel_7_API_33'
# options.automation_name = 'UiAutomator2'

# options.app_package = 'com.google.android.dialer'
# options.app_activity = 'com.google.android.dialer.extensions.GoogleDialtactsActivity'

desired_caps = {
    'deviceName': 'xxxx',
    'platformName': 'Android',
    'appPackage': '',
    'appActivity': '',
    'automationName': 'UiAutomator2'
}

appium_server_url = 'http://127.0.0.1:4723'
driver = webdriver.Remote(command_executor=appium_server_url,
                          desired_capabilities=desired_caps)


# driver = webdriver.Remote(command_executor=appium_server_url, options=options)

try:
    # 1. 定义数字与 Keycode 的映射关系 (Keycode 7 代表数字0，8代表1，以此类推)
    num_keycode = {
        '0': 7, '1': 8, '2': 9, '3': 10, '4': 11,
        '5': 12, '6': 13, '7': 14, '8': 15, '9': 16
    }
    # # 1. 找到数字 "5" 的按钮并点击
    # driver.find_element(AppiumBy.ID, 'com.android.calculator2:id/digit_5').click()
    # # 2. 找到加号 "+" 的按钮并点击
    # driver.find_element(AppiumBy.ID, 'com.android.calculator2:id/op_add').click()
    # # 3. 找到数字 "3" 的按钮并点击
    # driver.find_element(AppiumBy.ID, 'com.android.calculator2:id/digit_3').click()
    # # 4. 找到等号 "=" 的按钮并点击
    # driver.find_element(AppiumBy.ID, 'com.android.calculator2:id/eq').click()
    
    # # 5. 获取计算结果并打印出来
    # result = driver.find_element(AppiumBy.ID, 'com.android.calculator2:id/result').text
    # print("自动化测试获取到的计算结果是:", result)

    phone_number = "13812345678"
    # 2. 循环遍历电话号码，逐个模拟按下物理按键
    for digit in phone_number:
        driver.press_keycode(num_keycode[digit])
        sleep(2)  # 稍微停顿一下，模拟真实点击间隔
        
    print("通过模拟物理按键成功输入电话号码！")
    sleep(3)

except Exception as e:
    print("测试过程中发生了报错:", e)
finally:
    # 测试结束，关闭 App 会话
    driver.quit()
