# DNS PTR Record Auto Create Script

This PowerShell script automatically creates missing PTR (reverse DNS) records for existing A records in a Windows DNS environment.

Useful for maintaining DNS consistency and avoiding reverse lookup issues in enterprise networks.

## Features

- Scans DNS zones for A records
- Detects missing PTR records
- Automatically creates PTR records
- Helps maintain forward and reverse DNS consistency

## Use Case

In many environments, PTR records are not always created when A records are added.

This can cause issues with:

- Reverse DNS lookups
- Email systems
- Security tools
- Network troubleshooting

This script helps fix that automatically.

## Usage

1. Run PowerShell as Administrator
2. Execute the script:

```powershell
.\create-missing-ptr.ps1
```

3. Review output and confirm changes

Requirements
- Windows DNS Server
- PowerShell
- Administrator privileges

Full Guide  

For a detailed step-by-step explanation, see the full article:

👉 https://www.hiddenobelisk.com/how-to-automatically-create-missing-ptr-records-for-a-records-in-windows-dns-powershell-script/

Disclaimer

Test in a safe environment before running in production.
Use at your own risk.
