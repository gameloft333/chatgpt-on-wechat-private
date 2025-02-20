#!/bin/bash

# 定义颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== ChatGPT WeChat MP 快速部署脚本 ===${NC}"

# 检查并安装/更新 Nginx
check_and_install_nginx() {
    echo -e "${YELLOW}检查 Nginx...${NC}"
    
    # 检查是否安装
    if ! command -v nginx &> /dev/null; then
        echo -e "${YELLOW}Nginx 未安装，正在安装...${NC}"
        # 静默安装 Nginx
        if [ -f /etc/debian_version ]; then
            # Debian/Ubuntu 系统
            sudo apt-get update -qq
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nginx > /dev/null 2>&1
        elif [ -f /etc/redhat-release ]; then
            # CentOS/RHEL 系统
            sudo yum install -y nginx > /dev/null 2>&1
        else
            echo -e "${RED}不支持的操作系统${NC}"
            exit 1
        fi
        echo -e "${GREEN}Nginx 安装完成${NC}"
    else
        # 检查版本并更新
        CURRENT_VERSION=$(nginx -v 2>&1 | grep -o '[0-9.]*$')
        echo -e "${YELLOW}当前 Nginx 版本: ${CURRENT_VERSION}${NC}"
        
        if [ -f /etc/debian_version ]; then
            LATEST_VERSION=$(apt-cache policy nginx | grep Candidate | cut -d ':' -f 2 | tr -d ' ')
            if [ "$CURRENT_VERSION" != "$LATEST_VERSION" ]; then
                echo -e "${YELLOW}发现新版本: ${LATEST_VERSION}，正在更新...${NC}"
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade nginx > /dev/null 2>&1
                echo -e "${GREEN}Nginx 已更新到最新版本${NC}"
            else
                echo -e "${GREEN}Nginx 已是最新版本${NC}"
            fi
        elif [ -f /etc/redhat-release ]; then
            sudo yum check-update nginx > /dev/null 2>&1
            if [ $? -eq 100 ]; then
                echo -e "${YELLOW}发现新版本，正在更新...${NC}"
                sudo yum update -y nginx > /dev/null 2>&1
                echo -e "${GREEN}Nginx 已更新到最新版本${NC}"
            else
                echo -e "${GREEN}Nginx 已是最新版本${NC}"
            fi
        fi
    fi

    # 确保 Nginx 服务启动
    if ! systemctl is-active --quiet nginx; then
        echo -e "${YELLOW}启动 Nginx 服务...${NC}"
        sudo systemctl start nginx
    fi
    
    # 设置开机自启
    if ! systemctl is-enabled --quiet nginx; then
        echo -e "${YELLOW}设置 Nginx 开机自启...${NC}"
        sudo systemctl enable nginx > /dev/null 2>&1
    fi
}

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
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
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