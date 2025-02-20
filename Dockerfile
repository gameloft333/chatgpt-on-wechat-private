FROM python:3.8-slim

WORKDIR /app

# 安装基础依赖
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    gcc \
    python3-dev \
    libc-dev \
    libffi-dev \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# 复制项目文件
COPY . .

# 创建并激活虚拟环境
RUN python -m venv venv
ENV PATH="/app/venv/bin:$PATH"

# 安装依赖
RUN pip install --no-cache-dir -r requirements.txt
RUN pip install --no-cache-dir -r requirements-optional.txt

# 设置配置文件
# COPY config-template.json config.json

CMD ["python", "app.py"]