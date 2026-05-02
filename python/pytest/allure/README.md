# allure

一个测试报告的框架，支持多种语言，比如Python, java, ruby等。

## 安装

```bash
pip install allure-pytest
```

## 配置

```ini
addopts = --alluredir=temps --clean-alluredir
```

## 生成报告

```bash
allure generate -o report -c temps
```

## allure的几个装饰器

```python
import allure


@allure.epic
@allure.feature
@allure.store
@allure.title
def test_allure():
    pass
```