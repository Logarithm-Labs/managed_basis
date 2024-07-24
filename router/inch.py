import json
import requests
import argparse


apiUrl = "https://api.1inch.dev/swap/v6.0/42161/swap" # 42161 - ARB


if __name__ == '__main__':

    argparse = argparse.ArgumentParser()
    argparse.add_argument('--json_data_file', type=str, help='1inch swap params json file, should include src, dst, amount, from, slippage', required=True)
    argparse.add_argument('--output', type=str, help='Output file if needed', required=False)

    args = argparse.parse_args()

    with open(args.json_data_file, 'r') as f:
        data = json.loads(f.read())

    if not data:
        raise ValueError("Invalid json data")
    if not 'src' in data:
        raise ValueError("Invalid json data, src is required")
    if not 'dst' in data:
        raise ValueError("Invalid json data, dst is required")
    if not 'amount' in data:
        raise ValueError("Invalid json data, amount is required")
    if not 'from' in data:
        raise ValueError("Invalid json data, from is required")
    if not 'slippage' in data:
        raise ValueError("Invalid json data, slippage is required")

    # vsBZ4Am7CeBfpf7qbBd0ItcIlooL5xCC - API_KEY
    requestOptions = {
        "headers": {
            "Authorization": "Bearer vsBZ4Am7CeBfpf7qbBd0ItcIlooL5xCC"
        },
        "body": {},
        "params": {
            "src": data['src'], # tokenIn
            "dst": data['dst'], # tokenOut
            "amount": data['amount'], # amountIn
            "from": data['from'], # fromAddress
            "slippage": data['slippage'], # slippage
            "disableEstimate": "true" # turn off simulation
        }
    }

    # Prepare request components
    headers = requestOptions.get("headers", {})
    body = requestOptions.get("body", {})
    params = requestOptions.get("params", {})

    response = requests.get(apiUrl, headers=headers, params=params)
    if args.output:
        with open(args.output, 'w') as f:
            json.dump(response.json(), f)
    print(response.json()['tx']['data'])