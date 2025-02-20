#!/bin/bash

# 定义颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== ChatGPT WeChat MP 快速部署脚本 ===${NC}"
# 检查端口占用
check_port() {
    local port=$1
    if netstat -tuln | grep -q ":$port "; then
        local pid=$(lsof -t -i:$port)
        local process_name=$(ps -p $pid -o comm=)
        if [ "$port" = "80" ] && [ "$process_name" = "nginx" ]; then
            echo -e "${GREEN}✓ 端口 80 被 Nginx 正常占用${NC}"
            return 0
        else
            echo -e "${YELLOW}警告: 端口 $port 已被 $process_name (PID: $pid) 占用${NC}"
            echo -e "请选择操作："
            echo -e "1) 终止占用进程并继续部署"
            echo -e "2) 取消部署"
            echo -e "3) 强制继续部署（不推荐）"
            read -p "请输入选项 [1-3]: " choice
            
            case $choice in
                1)
                    echo -e "${YELLOW}正在终止进程 $process_name (PID: $pid)...${NC}"
                    if kill $pid; then
                        echo -e "${GREEN}✓ 进程已终止${NC}"
                        sleep 2  # 等待端口释放
                        if netstat -tuln | grep -q ":$port "; then
                            echo -e "${RED}错误：端口 $port 仍被占用，可能需要强制终止进程${NC}"
                            echo -e "建议执行: ${GREEN}sudo kill -9 $pid${NC}"
                            return 1
                        fi
                        return 0
                    else
                        echo -e "${RED}错误：无法终止进程，可能需要 sudo 权限${NC}"
                        return 1
                    fi
                    ;;
                2)
                    echo -e "${RED}部署已取消${NC}"
                    exit 1
                    ;;
                3)
                    echo -e "${YELLOW}警告：强制继续部署可能会导致端口冲突${NC}"
                    read -p "确定要继续吗？[y/N] " confirm
                    if [[ ! $confirm =~ ^[Yy]$ ]]; then
                        echo -e "${RED}部署已取消${NC}"
                        exit 1
                    fi
                    return 0
                    ;;
                *)
                    echo -e "${RED}无效的选项${NC}"
                    return 1
                    ;;
            esac
        fi
    fi
    return 0
}

# 检查系统类型
check_system_type() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        echo -e "${YELLOW}检测到操作系统: $OS${NC}"
        
        case $ID in
            "amzn")
                echo -e "${GREEN}检测到 Amazon Linux${NC}"
                PACKAGE_MANAGER="yum"
                NGINX_INSTALL_CMD="amazon-linux-extras enable nginx1 && yum clean metadata && yum -y install nginx"
                NGINX_SERVICE_CMD="systemctl"
                ;;
            "debian"|"ubuntu")
                echo -e "${GREEN}检测到 Debian/Ubuntu${NC}"
                PACKAGE_MANAGER="apt-get"
                NGINX_INSTALL_CMD="apt-get install -y nginx"
                ;;
            "rhel"|"centos"|"fedora")
                echo -e "${GREEN}检测到 RHEL/CentOS/Fedora${NC}"
                PACKAGE_MANAGER="yum"
                NGINX_INSTALL_CMD="yum install -y nginx"
                ;;
            *)
                echo -e "${RED}不支持的操作系统: $OS${NC}"
                exit 1
                ;;
        esac
    else
        echo -e "${RED}无法检测操作系统类型${NC}"
        exit 1
    fi
}

# 检查并安装/更新 Nginx
check_and_install_nginx() {
    echo -e "${YELLOW}检查 Nginx...${NC}"
    
    # 检查是否安装
    if ! command -v nginx &> /dev/null; then
        echo -e "${YELLOW}Nginx 未安装，正在安装...${NC}"
        
        if [ "$ID" = "amzn" ]; then
            echo -e "${YELLOW}配置 Amazon Linux Extras...${NC}"
            sudo amazon-linux-extras enable nginx1 > /dev/null 2>&1
            sudo yum clean metadata > /dev/null 2>&1
            sudo yum -y install nginx > /dev/null 2>&1
            
            # 创建必要的目录
            sudo mkdir -p /etc/nginx/conf.d
            sudo mkdir -p /var/log/nginx
            
            # 确保权限正确
            sudo chown -R root:root /etc/nginx
            sudo chmod -R 755 /etc/nginx
        else
            sudo $NGINX_INSTALL_CMD > /dev/null 2>&1
        fi
        
        echo -e "${GREEN}Nginx 安装完成${NC}"
    fi

    # 确保 Nginx 服务启动
    if [ "$ID" = "amzn" ]; then
        echo -e "${YELLOW}启动 Nginx 服务...${NC}"
        sudo systemctl daemon-reload
        sudo systemctl start nginx
        
        if ! systemctl is-active --quiet nginx; then
            echo -e "${RED}Nginx 启动失败，尝试修复...${NC}"
            # 检查 SELinux
            if command -v sestatus > /dev/null && [ "$(sestatus | grep 'Current mode' | awk '{print $3}')" != "disabled" ]; then
                echo -e "${YELLOW}配置 SELinux 允许 Nginx...${NC}"
                sudo setsebool -P httpd_can_network_connect 1
            fi
            # 重试启动
            sudo systemctl start nginx
        fi
        
        # 设置开机自启
        sudo systemctl enable nginx > /dev/null 2>&1
    else
        if ! systemctl is-active --quiet nginx; then
            echo -e "${YELLOW}启动 Nginx 服务...${NC}"
            sudo systemctl start nginx
        fi
        if ! systemctl is-enabled --quiet nginx; then
            echo -e "${YELLOW}设置 Nginx 开机自启...${NC}"
            sudo systemctl enable nginx > /dev/null 2>&1
        fi
    fi

    # 验证 Nginx 是否正常运行
    if ! systemctl is-active --quiet nginx; then
        echo -e "${RED}错误：Nginx 服务无法启动，请检查系统日志${NC}"
        echo -e "可以运行: ${GREEN}journalctl -u nginx.service${NC}"
        exit 1
    fi
}

# 安装 Docker 和 Docker Compose
install_docker() {
    # 检查 Docker 是否已安装
    if command -v docker &> /dev/null; then
        echo -e "${GREEN}✓ Docker 已安装${NC}"
    else
        echo -e "${YELLOW}安装 Docker...${NC}"
        curl -fsSL https://get.docker.com | bash -s docker
        sudo systemctl enable --now docker
    fi

    # 检查 Docker 服务状态
    if ! systemctl is-active --quiet docker; then
        echo -e "${YELLOW}启动 Docker 服务...${NC}"
        sudo systemctl start docker
    fi

    # 检查 Docker Compose 是否已安装
    if command -v docker-compose &> /dev/null || docker compose version &> /dev/null; then
        echo -e "${GREEN}✓ Docker Compose 已安装${NC}"
    else
        echo -e "${YELLOW}安装 Docker Compose...${NC}"
        sudo curl -L "https://github.com/docker/compose/releases/download/v2.23.0/docker-compose-$(uname -s)-$(uname -m)" \
            -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
    fi

    # 验证 Docker Compose 安装
    if ! docker-compose --version &> /dev/null && ! docker compose version &> /dev/null; then
        echo -e "${RED}错误：Docker Compose 安装失败${NC}"
        exit 1
    fi
}

# 部署 ollama-proxy
deploy_ollama_proxy() {
    echo -e "${YELLOW}部署 Ollama 代理服务...${NC}"
    sudo tee docker-compose.yml > /dev/null <<EOF
version: '3'
services:
  ollama-proxy:
    image: ghcr.io/ollama-webui/ollama-proxy:main
    ports:
      - "11435:8000"
    environment:
      - OLLAMA_API_BASE_URL=http://host.docker.internal:11434
    restart: unless-stopped
EOF

    sudo docker-compose up -d
    echo -e "${GREEN}Ollama 代理服务已启动${NC}"
}

# 主程序开始
echo -e "${GREEN}=== ChatGPT WeChat MP 快速部署脚本 ===${NC}"

# 检查端口占用
echo -e "${YELLOW}检查端口占用情况...${NC}"
while ! check_port 8080; do
    echo -e "${YELLOW}端口问题未解决，是否重试？[y/N]${NC}"
    read -r retry
    if [[ ! $retry =~ ^[Yy]$ ]]; then
        echo -e "${RED}部署已取消${NC}"
        exit 1
    fi
done

# 检查系统类型
check_system_type

# 安装 Docker 和 Docker Compose
install_docker
deploy_ollama_proxy

# 执行 Nginx 检查和安装
check_and_install_nginx

# 创建 Nginx 配置
echo -e "${YELLOW}配置 Nginx...${NC}"
NGINX_CONF="/etc/nginx/conf.d/wechat.conf"
if [ ! -f "$NGINX_CONF" ]; then
    echo -e "${YELLOW}创建 Nginx 配置文件...${NC}"
    sudo tee $NGINX_CONF > /dev/null <<EOF
server {
    listen 80;
    server_name $(curl -s ifconfig.me);  # 使用服务器IP

    location /wx {
        proxy_pass http://127.0.0.1:8080/wx;  # 添加了 /wx 路径
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;  # 添加协议头
        proxy_read_timeout 300;  # 增加超时时间
        proxy_connect_timeout 300;  # 增加连接超时
    }
}
EOF
    # 测试 Nginx 配置
    sudo nginx -t
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Nginx 配置成功${NC}"
        sudo systemctl reload nginx
    else
        echo -e "${RED}Nginx 配置错误，请检查${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}Nginx 配置文件已存在${NC}"
fi

# 检查 Python 版本
echo -e "${YELLOW}检查 Python 版本...${NC}"
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}错误：未找到 Python3，请先安装 Python3${NC}"
    exit 1
fi

# 创建并激活虚拟环境
echo -e "${YELLOW}创建虚拟环境...${NC}"
python3 -m venv venv
source venv/bin/activate

# 升级 pip
echo -e "${YELLOW}升级 pip...${NC}"
python3 -m pip install --upgrade pip

# 安装依赖
echo -e "${YELLOW}安装必需依赖...${NC}"
pip3 install -r requirements.txt

# 安装可选依赖
echo -e "${YELLOW}安装可选依赖...${NC}"
if [ -f "requirements-optional.txt" ]; then
    pip3 install -r requirements-optional.txt
fi

# 创建日志文件
echo -e "${YELLOW}创建日志文件...${NC}"
touch nohup.out

# 启动服务
echo -e "${GREEN}启动服务...${NC}"
nohup python3 app.py > nohup.out 2>&1 &

# 等待服务启动
echo -e "${YELLOW}等待服务启动...${NC}"
sleep 3

# 检查服务状态
if pgrep -f "python3 app.py" > /dev/null; then
    echo -e "${GREEN}服务已成功启动！${NC}"
    echo -e "${YELLOW}正在显示日志输出...${NC}"
    echo -e "${YELLOW}提示：${NC}"
    echo -e "1. 请在微信公众平台配置服务器URL: http://你的域名/wx"
    echo -e "2. 请确保已将服务器IP添加到公众号IP白名单"
    echo -e "3. 如需查看 Nginx 日志：${GREEN}sudo tail -f /var/log/nginx/error.log${NC}"
    echo -e "4. 使用 Ctrl+C 可以停止查看日志，但服务会继续运行"
    echo -e "5. 如需停止服务，请运行：${GREEN}pkill -f 'python3 app.py'${NC}"
    tail -f nohup.out
else
    echo -e "${RED}服务启动失败，请检查日志文件 nohup.out${NC}"
fi