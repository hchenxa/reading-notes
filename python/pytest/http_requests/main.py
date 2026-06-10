import json
import requests
# import jsonpath



url = 'https://jsonplaceholder.typicode.com/posts/1' 


resp = requests.request('GET', url)
# resp = requests.get(url)
if resp.status_code == 200:
    data = resp.json()
    print(f"{data}")
    print(json.dumps(data, indent=4, ensure_ascii=False))
    # print(f"{data.get('body')}")