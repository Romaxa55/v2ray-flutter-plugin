class V2RayConfigHelper {
  /// Create VLESS configuration
  static Map<String, dynamic> createVlessConfig({
    required String serverAddress,
    required int serverPort,
    required String uuid,
    String? path,
    String? host,
    bool enableTLS = true,
    int localPort = 1080,
  }) {
    return {
      "log": {"loglevel": "warning"},
      "inbounds": [
        {
          "listen": "127.0.0.1",
          "protocol": "socks",
          "settings": {"userLevel": 8, "auth": "noauth", "udp": true},
          "port": localPort,
          "tag": "socks"
        },
        {
          "listen": "127.0.0.1",
          "protocol": "shadowsocks",
          "settings": {
            "level": 8,
            "method": "chacha20-ietf-poly1305",
            "udp": false,
            "password": "123456",
            "ota": true,
            "network": "tcp,udp"
          },
          "port": 10808,
          "tag": "shadowsocks"
        },
        {
          "listen": "127.0.0.1",
          "protocol": "dokodemo-door",
          "settings": {"address": "127.0.0.1"},
          "port": 62789,
          "tag": "api"
        },
        {
          "listen": "127.0.0.1",
          "protocol": "dokodemo-door",
          "settings": {
            "address": "1.1.1.1",
            "userLevel": 0,
            "port": 53,
            "network": "tcp,udp",
            "timeout": 10
          },
          "port": 62790,
          "tag": "inDns"
        }
      ],
      "outbounds": [
        {
          "streamSettings": {
            "network": "ws",
            "security": enableTLS ? "tls" : "none",
            "tlsSettings": enableTLS
                ? {
                    "alpn": [],
                    "fingerprint": "chrome",
                    "allowInsecure": true,
                    "serverName": host ?? serverAddress
                  }
                : null,
            "wsSettings": {
              "headers": {"Host": host ?? ""},
              "path": path ?? "/"
            }
          },
          "protocol": "vless",
          "tag": "proxy",
          "settings": {
            "vnext": [
              {
                "port": serverPort,
                "address": serverAddress,
                "users": [
                  {
                    "id": uuid,
                    "level": 0,
                    "encryption": "none",
                    "flow": "",
                    "email": ""
                  }
                ]
              }
            ]
          },
          "mux": {
            "concurrency": 50,
            "enabled": true,
            "xudpConcurrency": 128,
            "xudpProxyUDP443": "allow"
          }
        },
        {
          "streamSettings": {
            "sockopt": {"tcpNoDelay": true}
          },
          "protocol": "freedom",
          "tag": "direct",
          "settings": {
            "domainStrategy": "UseIPv4",
            "fragment": {
              "interval": "10-100",
              "length": "80-250",
              "packets": "tlshello"
            },
            "userLevel": 8
          }
        },
        {
          "tag": "block",
          "protocol": "blackhole",
          "settings": {
            "response": {"type": "http"}
          }
        }
      ],
      "api": {
        "services": ["StatsService"],
        "tag": "api"
      },
      "dns": {
        "servers": [
          {"skipFallback": false, "address": "8.8.8.8"},
          {"skipFallback": false, "address": "1.1.1.1"}
        ],
        "disableFallbackIfMatch": true,
        "disableCache": true,
        "tag": "dnsQuery",
        "queryStrategy": "UseIPv4",
        "disableFallback": true
      },
      "stats": {},
      "routing": {
        "domainStrategy": "IPIfNonMatch",
        "balancers": [],
        "rules": [
          {
            "type": "field",
            "inboundTag": ["api"],
            "outboundTag": "api"
          },
          {
            "type": "field",
            "inboundTag": ["inDns"],
            "outboundTag": "outDns"
          },
          {
            "type": "field",
            "inboundTag": ["dnsQuery"],
            "outboundTag": "proxy"
          }
        ]
      },
      "policy": {
        "system": {
          "statsOutboundUplink": true,
          "statsInboundDownlink": true,
          "statsOutboundDownlink": true,
          "statsInboundUplink": true
        },
        "levels": {
          "8": {
            "downlinkOnly": 1,
            "statsUserDownlink": false,
            "uplinkOnly": 1,
            "statsUserUplink": false,
            "connIdle": 30,
            "bufferSize": 0,
            "handshake": 4
          }
        }
      }
    };
  }
}

