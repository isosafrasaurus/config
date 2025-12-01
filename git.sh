#!/bin/bash

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

if command_exists git; then
  echo "Git is installed."
else
  echo "Git is not installed. Please install Git first."
  exit 1
fi

if command_exists gh; then
  echo "GitHub CLI (gh) is installed."
else
  echo "GitHub CLI is not installed. Please install it first (https://cli.github.com/)."
  exit 1
fi

echo "Checking GitHub authentication status..."
if gh auth status >/dev/null 2>&1; then
  echo "You are already logged into GitHub CLI."
else
  echo "You are not logged in. Initiating login..."
  gh auth login
fi

echo "Fetching user information from GitHub..."
GH_NAME=$(gh api user --template '{{if .name}}{{.name}}{{else}}{{.login}}{{end}}')

GH_EMAIL=$(gh api user --template '{{.email}}')
GH_LOGIN=$(gh api user --template '{{.login}}')
GH_ID=$(gh api user --template '{{.id}}')

if [ -z "$GH_EMAIL" ] || [ "$GH_EMAIL" == "<no value>" ]; then
  echo "No public email found. Configuring with GitHub noreply email."
  GH_EMAIL="${GH_ID}+${GH_LOGIN}@users.noreply.github.com"
fi

git config --global user.name "$GH_NAME"
git config --global user.email "$GH_EMAIL"

echo "User Name:  $(git config --global user.name)"
echo "User Email: $(git config --global user.email)"
