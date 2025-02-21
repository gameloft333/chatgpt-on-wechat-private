#!/bin/bash

# 定义颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 检查端口占用
check_port() {
    local port=$1
    # 使用更可靠的ss命令替代netstat
    if ss -tuln | grep -q ":$port "; then
        # 获取所有相关PID（修复多PID处理）
        local pids=($(lsof -t -i :$port 2>/dev/null | tr '\n' ' '))
        
        if [ ${#pids[@]} -eq 0 ]; then
            echo -e "${YELLOW}警告: 端口 $port 被占用但无法获取进程信息${NC}"
            return 1
        fi

        # 处理多个PID的情况
        for pid in "${pids[@]}"; do
            local process_name=$(ps -p $pid -o comm= 2>/dev/null || echo "未知进程")
            
            # 特殊处理Nginx（约15-17行）
            if [ "$port" = "80" ] && [ "$process_name" = "nginx" ]; then
                echo -e "${GREEN}✓ 端口 80 被 Nginx 正常占用${NC}"
                continue
            fi

            echo -e "${YELLOW}警告: 端口 $port 已被 $process_name (PID: $pid) 占用${NC}"
        done

        # 统一处理用户选择（约20-60行）
        echo -e "请选择操作："
        echo -e "1) 终止所有占用进程并继续部署"
        echo -e "2) 取消部署"
        echo -e "3) 强制继续部署（不推荐）"
        read -p "请输入选项 [1-3]: " choice
        
        case $choice in
            1)
                for pid in "${pids[@]}"; do
                    echo -e "${YELLOW}正在终止进程 (PID: $pid)...${NC}"
                    if sudo kill -9 $pid 2>/dev/null; then
                        echo -e "${GREEN}✓ 进程已终止${NC}"
                    else
                        echo -e "${RED}错误：无法终止进程 $pid${NC}"
                        return 1
                    fi
                done
                sleep 2
                return 0
                ;;
            2)
                echo -e "${RED}部署已取消${NC}"
                exit 1
                ;;
            3)
                echo -e "${YELLOW}警告：强制继续部署可能会导致服务异常${NC}"
                return 0
                ;;
            *)
                echo -e "${RED}无效的选项${NC}"
                return 1
                ;;
        esac
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

# 修改端口冲突处理逻辑
handle_port_conflict() {
    local port=$1
    echo -e "${YELLOW}检测到${port}端口占用，正在分析来源...${NC}"
    
    # 获取占用进程信息
    local pid=$(lsof -t -i :$port)
    local process_info=$(ps -p $pid -o comm=,args= 2>/dev/null)
    
    # 判断是否为Docker容器占用
    if [[ "$process_info" == *"docker-proxy"* ]]; then
        echo -e "${YELLOW}发现Docker容器占用端口，尝试安全清理...${NC}"
        local container_id=$(docker ps --filter "publish=$port" --format "{{.ID}}")
        if [ -n "$container_id" ]; then
            echo -e "${YELLOW}正在停止冲突容器 $container_id ...${NC}"
            docker stop $container_id && docker rm $container_id
            sleep 2
        else
            echo -e "${RED}错误：未能找到对应容器，建议手动处理${NC}"
            exit 1
        fi
    else
        echo -e "${RED}错误：端口被非Docker进程占用，进程信息：${NC}"
        echo "进程ID: $pid"
        echo "进程详情: $process_info"
        echo -e "${YELLOW}请选择操作："
        echo -e "1) 手动终止进程后继续"
        echo -e "2) 退出部署脚本"
        read -p "请输入选项 [1-2]: " choice
        case $choice in
            1) echo -e "${YELLOW}请手动处理后再运行脚本${NC}"; exit 1 ;;
            *) echo -e "${RED}部署已取消${NC}"; exit 1 ;;
        esac
    fi
}

# 部署 ollama-proxy
deploy_ollama_proxy() {
    echo -e "${YELLOW}部署 Ollama 代理服务...${NC}"
    
    # 新增端口释放检查
    if lsof -i :11434 >/dev/null; then
        handle_port_conflict 11434
    fi
    
    # 新增服务白名单检查
    PROTECTED_CONTAINERS="1Panel|ollama"
    if docker ps --format '{{.Names}}' | grep -qE "$PROTECTED_CONTAINERS"; then
        echo -e "${YELLOW}检测到关键服务容器，跳过端口冲突检查${NC}"
        return 0
    fi
    
    sudo tee docker-compose.yml > /dev/null <<EOF
version: '3'
services:
  ollama-proxy:
    image: ollama/ollama
    network_mode: "host"  # 改为host模式避免端口冲突
    restart: unless-stopped
    ports:
      - "${API_PORT}:${API_PORT}"
EOF

    sudo docker-compose up -d
    echo -e "${GREEN}Ollama 代理服务已启动${NC}"
    
    # 新增服务健康检查
    echo -e "${YELLOW}等待Ollama服务初始化...${NC}"
    local retries=0
    until curl -s http://localhost:11434/api/version >/dev/null || [ $retries -eq 30 ]; do
        sleep 1
        echo -n "."
        ((retries++))
    done
    if [ $retries -eq 30 ]; then
        echo -e "\n${RED}错误：Ollama服务启动超时${NC}"
        exit 1
    fi
    echo -e "\n${GREEN}✓ Ollama服务已就绪${NC}"
}

# 新增服务依赖检查
check_ollama_service() {
    echo -e "${YELLOW}检查Ollama服务状态...${NC}"
    if curl -s --connect-timeout 3 http://localhost:11434/api/version >/dev/null; then
        echo -e "${GREEN}✓ 检测到现有Ollama服务${NC}"
        return 0
    else
        echo -e "${YELLOW}未检测到运行中的Ollama服务，开始部署...${NC}"
        deploy_ollama_proxy
        return $?
    fi
}

# 主程序开始
echo -e "${GREEN}=== ChatGPT WeChat MP 快速部署脚本 ===${NC}"

# 在部署ollama前添加端口检查
check_port $(jq -r '.open_ai_api_base | split(":")[2] | split("/")[0]' config.json)
check_port 8080   # 原有8080检查

# 检查系统类型
check_system_type

# 安装 Docker 和 Docker Compose
install_docker

# 主程序调用
check_ollama_service || exit 1

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
        
        # 超时设置增强（单位：秒）
        proxy_read_timeout 300;  # 增加超时时间
        proxy_connect_timeout 300;  # 增加连接超时
        proxy_http_version 1.1;  # 添加HTTP协议优化
        proxy_set_header Connection "";
        proxy_send_timeout 300;
        
        # 缓冲区优化
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
    }

    location /v1 { # 新增模型服务代理
        proxy_pass http://127.0.0.1:${API_PORT}/v1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
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
if [ ! -d "venv" ]; then
    echo -e "${YELLOW}创建虚拟环境...${NC}"
    python3 -m venv venv
fi
source venv/bin/activate

# 检查依赖是否已安装
REQUIREMENTS_HASH=$(sha1sum requirements.txt | cut -d' ' -f1)
CACHED_HASH_FILE=".requirements_hash"

if [ ! -f "$CACHED_HASH_FILE" ] || [ "$REQUIREMENTS_HASH" != "$(cat $CACHED_HASH_FILE)" ]; then
    echo -e "${YELLOW}升级 pip...${NC}"
    python3 -m pip install --upgrade pip

    echo -e "${YELLOW}安装必需依赖...${NC}"
    pip3 install -r requirements.txt
    echo "$REQUIREMENTS_HASH" > "$CACHED_HASH_FILE"
else
    echo -e "${GREEN}✓ 依赖已是最新，跳过安装${NC}"
fi

# 可选依赖安装优化
if [ -f "requirements-optional.txt" ]; then
    OPTIONAL_HASH=$(sha1sum requirements-optional.txt | cut -d' ' -f1)
    CACHED_OPT_HASH_FILE=".optional_requirements_hash"
    
    if [ ! -f "$CACHED_OPT_HASH_FILE" ] || [ "$OPTIONAL_HASH" != "$(cat $CACHED_OPT_HASH_FILE)" ]; then
        echo -e "${YELLOW}安装可选依赖...${NC}"
        pip3 install -r requirements-optional.txt
        echo "$OPTIONAL_HASH" > "$CACHED_OPT_HASH_FILE"
    else
        echo -e "${GREEN}✓ 可选依赖已是最新，跳过安装${NC}"
    fi
fi

# 创建日志文件
echo -e "${YELLOW}创建日志文件...${NC}"
touch nohup.out

# 动态获取API端口（约420-438行）
API_PORT=$(jq -r '.open_ai_api_base | split(":")[2] | split("/")[0]' config.json)
if [[ ! $API_PORT =~ ^[0-9]+$ ]]; then
    echo -e "${RED}错误：无法从 open_ai_api_base 中提取有效端口号${NC}"
    exit 1
fi

JQ_CONDITION=".wechatmp_port == 8080 and (.open_ai_api_base | test(\"^http(s)?://\"))"

if ! jq -e "${JQ_CONDITION}" config.json >/dev/null; then
    echo -e "${YELLOW}建议配置检查未通过，请确认以下关键设置：${NC}"
    echo -e "${GREEN}{
  \"wechatmp_port\": 8080,
  \"open_ai_api_base\": \"服务端URL（建议格式：http://IP:${API_PORT}/v1）\"
}${NC}"
    echo -e "允许的格式示例："
    echo -e "• http://localhost:11434/v1"
    echo -e "• http://127.0.0.1:11434/v1"
    echo -e "• http://47.129.174.124:11434/v1"
    echo -e "• http://[::1]:11434/v1 (IPv6)"
    echo -e "${YELLOW}当前配置内容：${NC}"
    jq . config.json
    
    read -p "是否继续部署？(y/n) " choice
    case "$choice" in
        y|Y) echo -e "${YELLOW}强制继续部署...${NC}" ;;
        *) echo -e "${RED}部署已取消${NC}"; exit 1 ;;
    esac
else
    echo -e "${GREEN}✓ 通过基础配置检查${NC}"
fi

# 修改服务启动方式（约456行）
echo -e "${GREEN}启动服务...${NC}"
nohup python3 app.py >> nohup.out 2>&1 &
sleep 2  # 确保进程启动

# 等待服务启动
echo -e "${YELLOW}等待服务启动...${NC}"
sleep 3

# 新增服务验证模块
echo -e "\n${YELLOW}=== 服务状态验证 ===${NC}"

# 安装jq用于JSON解析
if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}安装jq工具...${NC}"
    sudo yum install -y jq || sudo apt-get install -y jq
fi
# 添加进程守护检查（约513-532行）
echo -e "\n${YELLOW}=== 服务守护配置 ===${NC}"
if pgrep -f "python3 app.py" > /dev/null; then
    echo -e "${GREEN}✓ 服务进程已守护 (PID: $(pgrep -f "python3 app.py"))${NC}"
    echo -e "${YELLOW}进程管理命令：${NC}"
    echo -e "启动: ${GREEN}nohup python3 app.py >> nohup.out 2>&1 &${NC}"
    echo -e "停止: ${GREEN}pkill -f 'python3 app.py'${NC}"
    echo -e "重启: ${GREEN}pkill -f 'python3 app.py' && nohup python3 app.py >> nohup.out 2>&1 &${NC}"
    echo -e "状态: ${GREEN}pgrep -f 'python3 app.py'${NC}"
else
    echo -e "${RED}× 服务进程启动失败！${NC}"
    exit 1
fi

# 创建验证日志文件
VALIDATION_LOG="deployment_checks.log"
echo -e "服务验证日志 $(date)\n" > $VALIDATION_LOG

# 验证Ollama服务
echo -e "${YELLOW}[1/3] 验证Ollama服务...${NC}"
    echo -e "3. 重新启动服务：${GREEN}python3 app.py${NC}"
    echo -e "\n=== Ollama服务状态 ==="
    echo "API版本: $(curl -s http://localhost:11434/api/version | jq .)"
    echo "已加载模型:"
    curl -s http://localhost:11434/api/tags | jq '.models[].name'
} | tee -a $VALIDATION_LOG

# 修改后的模型验证
echo "已加载模型:"
MODEL_LIST=$(curl -s http://localhost:11434/api/tags | jq -r '.models[].name')
echo "$MODEL_LIST"
if echo "$MODEL_LIST" | grep -q "deepseek-r1:14b"; then
    echo -e "${GREEN}✓ 目标模型已加载${NC}"
else
    echo -e "${RED}× 未找到 deepseek-r1:14b 模型${NC}"
    exit 1
fi

# 验证对话接口
echo -e "\n${YELLOW}[2/3] 测试对话接口...${NC}"
{
    echo -e "=== 对话接口测试 ==="
    curl -s http://localhost:11434/v1/chat/completions \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer sk-any-string" \
      -d '{"model": "deepseek-r1:14b", "messages": [{"role": "user", "content": "你好"}]}' \
      | jq '.choices[0].message.content'
} | tee -a $VALIDATION_LOG

# 验证微信服务
echo -e "\n${YELLOW}[3/3] 验证微信服务连通性...${NC}"
{
    echo -e "=== 微信服务检查 ==="
    echo "Nginx状态: $(systemctl is-active nginx 2>/dev/null || echo '未安装')"
    echo "应用服务进程: $(pgrep -f 'python3 app.py')"
    echo "端口监听状态:"
    sudo netstat -tulnp | grep -E "${API_PORT}|8080"
} | tee -a $VALIDATION_LOG

# 输出验证结果
echo -e "\n${GREEN}验证完成，完整日志请查看: ${PWD}/$VALIDATION_LOG${NC}"
echo -e "${YELLOW}关键指标检查："
echo -e "• Ollama模型加载: $(grep -q 'deepseek-r1:14b' $VALIDATION_LOG && echo '成功' || echo '失败')"
echo -e "• 对话接口响应: $(grep -q '你好' $VALIDATION_LOG && echo '正常' || echo '异常')"
echo -e "• 服务进程状态: $(pgrep -f 'python3 app.py' &> /dev/null && echo '运行中' || echo '未运行')${NC}"
# 移除原来的tail命令（约525行）
# 改为提示查看日志的方法
echo -e "\n${YELLOW}日志查看方式：${NC}"
echo -e "实时日志: ${GREEN}tail -f nohup.out${NC}"
echo -e "历史日志: ${GREEN}cat nohup.out${NC}"

# 新增服务状态检查提示（添加在脚本末尾）
echo -e "\n${YELLOW}=== 服务启动状态检查 ===${NC}"
if pgrep -f "python3 app.py" > /dev/null; then
    echo -e "${GREEN}✓ 服务已成功启动！${NC}"
    echo -e "${YELLOW}操作指引：${NC}"
    echo -e "1. 请在微信公众平台配置服务器URL: http://$(curl -s ifconfig.me)/wx"
    echo -e "2. 请确保已将服务器IP ($(curl -s ifconfig.me)) 添加到公众号IP白名单"
    echo -e "3. 实时日志查看（Ctrl+C退出）：${GREEN}tail -f nohup.out${NC}"
    echo -e "4. Nginx错误日志查看：${GREEN}sudo tail -f /var/log/nginx/error.log${NC}"
    echo -e "5. 停止服务命令：${GREEN}pkill -f 'python3 app.py' && docker-compose down${NC}"
    
    # 保留日志跟踪功能
    echo -e "\n${YELLOW}正在进入实时日志监控...${NC}"
    tail -f nohup.out
else
    echo -e "${RED}× 服务启动异常！请检查：${NC}"
    echo -e "1. 查看错误日志：${GREEN}cat nohup.out${NC}"
    echo -e "2. 检查端口占用：${GREEN}netstat -tulnp | grep -E "${API_PORT}"${NC}"
    echo -e "3. 重新启动服务：${GREEN}python3 app.py${NC}"
    exit 1
fi