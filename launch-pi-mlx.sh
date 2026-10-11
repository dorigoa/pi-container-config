# -r off, otherwise the model do not understand the request (Qwen already has reasoning on)
pi-box -u http://localhost:8080/v1 -c 262144 -o 64536 -t medium -r off -m "mlx-community/Qwen3.8-27B-4bit"
