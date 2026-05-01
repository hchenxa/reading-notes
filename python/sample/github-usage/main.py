import requests


if __name__ == '__main__':
    url = "https://api.github.com/orgs/stolostron/repos"
    # url += "?q=language:python+sort:stars+stars:>100000"

    headers = {"Accept": "application/vnd.github.v3+json"}
    # headers = {"Accept": "text/html"}
    r = requests.get(url, headers=headers)
    print(f"Status code: {r.status_code}")

    response_dict = r.json()

    print(response_dict)
