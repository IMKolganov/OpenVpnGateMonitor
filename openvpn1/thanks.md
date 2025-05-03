## 🙏 THANKS

This project builds upon the outstanding work of many contributors in the open-source community. In particular, special thanks go to:

### 🐳 [kylemanna/docker-openvpn](https://github.com/kylemanna/docker-openvpn)
A lightweight, Alpine-based Docker image for OpenVPN with built-in Easy-RSA automation.  
It served as both the conceptual and structural foundation for this project.  
Inspired by its clear architecture and minimal setup workflow.

### 🔐 [Easy-RSA](https://github.com/OpenVPN/easy-rsa)
Easy-RSA is the standard toolkit for generating and managing a Public Key Infrastructure (PKI) for OpenVPN.  
Included here via Alpine package, and automatically bootstrapped if missing.

### 🛡 OpenVPN
OpenVPN is the core of this container and the main service exposed.  
Its flexibility and robust features continue to make secure networking simple and powerful.

---

## 🛠 Stack and Tools Used

| Component          | Purpose                                     |
|--------------------|---------------------------------------------|
| **Alpine Linux**   | Small base image for performance & size     |
| **OpenVPN**        | Secure VPN server                           |
| **Easy-RSA v3**    | PKI & certificate management                |
| **iptables**       | NAT and VPN routing                         |
| **bash**           | Entrypoint scripting                        |
| **docker-compose** | Multi-instance orchestration (UDP + TCP)   |

---

## 🤝 Contributing

Thanks to everyone who shares knowledge and improvements with the open-source world.  
Your ideas, patterns, and code examples help push the ecosystem forward.
