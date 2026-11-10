# 🐧 Linux Kernel Automated Update Script / Mise à jour automatisée du Noyau Linux

An interactive, smart, and safe Bash script to update or change the Ubuntu Mainline Linux kernel with an advanced terminal GUI.
*Un script Bash interactif, intelligent et sécurisé pour mettre à jour ou changer le noyau Linux Mainline d'Ubuntu via une interface terminal avancée.*

---

## 🇫🇷 Version Française

Ce script automatise la récupération, la sélection et l'installation des noyaux Linux officiels depuis le dépôt d'Ubuntu PPA Mainline. Il dispose d'une interface en grille interactive et de sécurités avancées.

### ✨ Fonctionnalités
* **Menu de sélection interactif en grille** : Navigation au clavier (Flèches) avec système de pagination par blocs de 60 versions (touches `+` et `-`).
* **Inhibition stricte du clavier** : Sécurisation des saisies utilisateur (seules les touches valides sont acceptées).
* **Bascule automatique de sécurité** : Si le mode `lowlatency` est sélectionné mais indisponible sur le serveur (comme sur les noyaux récents v6.x/v7.x), le script bascule automatiquement sur la version `generic` correspondante pour éviter un crash.
* **Affichage stylisé** : Utilisation de couleurs ANSI et d'effets visuels clairs pour une lecture optimale.

### 📋 Prérequis
* Distribution Linux basée sur Ubuntu/Debian (Ubuntu, Linux Mint, Pop!_OS, etc.).
* Architecture **64-bits** (`amd64`).
* Droits `sudo` pour l'installation des paquets.
* Une connexion Internet active.

### 🚀 Utilisation
```bash
# Rendre le script exécutable
chmod +x .majnoyau.sh

# Lancer le script
./.majnoyau.sh
```

### 🔒 Compilation en Binaire (Optionnel)
Si vous souhaitez distribuer ce script sur un parc de machines sans dévoiler le code source, vous pouvez le compiler en binaire exécutable à l'aide de `shc` :
```bash
sudo apt install shc gcc -y
shc -fr .majnoyau.sh
# Votre binaire sécurisé et chiffré sera généré sous le nom : .majnoyau.sh.x
```

---

## 🇬🇧 English Version : 'update_kernel_en-v2.sh'

This script automates the retrieval, selection, and installation of official Linux kernels from the Ubuntu PPA Mainline repository. It features an interactive grid GUI and advanced safety guardrails.

### ✨ Features
* **Interactive Grid Menu**: Keyboard-driven navigation (Arrow keys) with a pagination system stepping through blocks of 60 versions (using `+` and `-` keys).
* **Strict Input Inhibition**: Prevents unexpected user inputs (only targeted valid keys are captured).
* **Automatic Safety Fallback**: If `lowlatency` mode is chosen but unavailable on the remote server (common with newer v6.x/v7.x kernels), the script automatically falls back to the matching `generic` flavor to prevent installation failure.
* **Stylized Interface**: Uses ANSI colors and clear layout formatting for optimal readability.

### 📋 Prerequisites
* Ubuntu/Debian-based Linux distribution (Ubuntu, Linux Mint, Pop!_OS, etc.).
* **64-bit** architecture (`amd64`).
* `sudo` privileges to handle package installations.
* Active internet connection.

### 🚀 Usage
```bash
# Make the script executable
chmod +x update_kernel_en-v2.sh

# Run the script
bash update_kernel_en-v2.sh
```

### 🔒 Compile to a Binary (Optional)
If you wish to deploy this script across a pool of machines without revealing its plaintext source code, you can compile it into a standalone binary using `shc`:
```bash
sudo apt install shc gcc -y
shc -fr update_kernel_en-v2.sh
# Your encrypted, secure binary will be generated as: update_kernel_en-v2.sh.x
```

---

## 📄 License & Credits
* **Author / Auteur** : RISTOVSKI Nicolas
* **Update / Mise à jour** : 2026-11
* Open-source project. Feel free to fork, improve, and submit pull requests!
* *Projet open-source. N'hésitez pas à forker, améliorer et proposer des pull requests !*
