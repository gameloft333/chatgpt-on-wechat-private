#!/bin/bash

echo "=== ChatGPT WeChat 部署报告 ===" > deploy_report.txt
echo "部署开始时间: $(date)" >> deploy_report.txt

# 停止并删除现有容器
echo "1. 停止现有容器..."
docker stop chatgpt-on-wechat 2>/dev/null || true
docker rm chatgpt-on-wechat 2>/dev/null || true
echo "✓ 已停止并删除现有容器" >> deploy_report.txt

# 清理未使用的容器和缓存
echo "2. 清理系统..."
docker system prune -f
echo "✓ 系统清理完成" >> deploy_report.txt

# 重新构建镜像
echo "3. 开始构建新镜像..."
docker-compose -f docker-compose.250220.yml build --no-cache
BUILD_STATUS=$?
if [ $BUILD_STATUS -eq 0 ]; then
    echo "✓ 镜像构建成功" >> deploy_report.txt
else
    echo "✗ 镜像构建失败" >> deploy_report.txt
    exit 1
fi

# 启动新容器
echo "4. 启动容器..."
docker-compose -f docker-compose.250220.yml up -d
UP_STATUS=$?
if [ $UP_STATUS -eq 0 ]; then
    echo "✓ 容器启动成功" >> deploy_report.txt
else
    echo "✗ 容器启动失败" >> deploy_report.txt
    exit 1
fi

# 等待服务启动并检查状态
echo "5. 检查服务状态..."
sleep 5

# 检查容器是否正常运行
CONTAINER_STATUS=$(docker ps -f name=chatgpt-on-wechat --format '{{.Status}}')
if [[ $CONTAINER_STATUS == *"Up"* ]]; then
    echo "✓ 服务运行正常" >> deploy_report.txt
    
    # 检查服务日志中是否有错误
    ERROR_COUNT=$(docker logs chatgpt-on-wechat 2>&1 | grep -i "error" | wc -l)
    if [ $ERROR_COUNT -eq 0 ]; then
        echo "✓ 服务日志无错误" >> deploy_report.txt
    else
        echo "⚠ 服务日志中发现 $ERROR_COUNT 个错误，请检查详细日志" >> deploy_report.txt
    fi
else
    echo "✗ 服务可能未正常运行，请检查日志" >> deploy_report.txt
fi

# 检查端口监听状态
if netstat -tuln | grep -q ":8080"; then
    echo "✓ 端口8080已正常监听" >> deploy_report.txt
else
    echo "⚠ 端口8080未监听，请检查配置" >> deploy_report.txt
fi

# 完成部署报告
echo "部署结束时间: $(date)" >> deploy_report.txt
echo "容器ID: $(docker ps -q -f name=chatgpt-on-wechat)" >> deploy_report.txt
echo "容器状态: $CONTAINER_STATUS" >> deploy_report.txt

# 显示部署报告
echo -e "\n=== 部署报告 ==="
cat deploy_report.txt

echo -e "\n提示："
echo "1. 请确保已在微信公众平台配置了服务器信息"
echo "2. 请确保已将服务器IP添加到公众号IP白名单"
echo "3. 如需查看详细日志，请运行: docker logs -f chatgpt-on-wechat" 