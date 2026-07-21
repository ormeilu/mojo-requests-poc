# Fetch your public IP info from ipinfo.io and print selected fields.
#
# Run with: pixi run mojo -I . examples/ipinfo.mojo
#
# Note: the bare https://ipinfo.io URL returns an HTML landing page; the /json
# endpoint is the one that returns a JSON document we can parse.

import requests


def main() raises:
    var response = requests.get("https://ipinfo.io/json", timeout=15.0)
    print(response)  # <Response [200 OK]>  (like Python's repr)
    print("status:", response.status_code, "| ok:", response.ok())
    print("is_redirect:", response.is_redirect())

    # Raw body, line by line (like r.content / r.iter_lines()).
    print("\n-- iter_lines --")
    for line in response.iter_lines():
        print(line)

    # Parsed JSON access.
    var data = response.json()
    print("\n-- parsed --")
    print("ip:      ", data["ip"].as_string())
    print("city:    ", data["city"].as_string())
    print("region:  ", data["region"].as_string())
    print("country: ", data["country"].as_string())
    print("org:     ", data["org"].as_string())
