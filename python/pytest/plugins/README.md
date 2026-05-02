# 常见的plugins


## pytest-html
用来生成Html报表的

## pytest-xdist

并发执行

`pytest -n x`

## pytest-rerunfailures

失败下重试

`pytest --reruns 5 --reruns-delay 1`

失败5次算失败，每次重试的时候等待1s

## pytest-result-log

可配置在`pytest.ini`文件里

```ini
log_file=./logs/pytest.log
log_file_level=info
log_file_format= %(levelname)-8s %(asctime)s [%(name)s:%(lineo)s] : %(message)s
log_file_date_format = %Y-%m-%d %H:%M:%S

; 记录用例执行结果
result_log_enable = 1
; 记录用例分割线
result_log_separator = 1
; 分割线等级
result_log_level_separator = warning
; 异常信息等级
result_log_level_verbose = info
```