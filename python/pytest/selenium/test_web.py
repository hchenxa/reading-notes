from time import sleep

from selenium import webdriver


def test_web():
    driver = webdriver.Chrome()
    driver.get("https://www.baidu.com")
    sleep(5)
    driver.quit()