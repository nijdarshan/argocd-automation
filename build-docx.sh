#!/bin/bash
# Build the handover Word document from markdown sources
# Usage: ./build-docx.sh
# Output: VMO2_Hub_Handover.docx

set -e
DOCS_DIR="$(cd "$(dirname "$0")/docs" && pwd)"
OUT_DIR="$(cd "$(dirname "$0")" && pwd)"
MASTER="/tmp/vmo2-handover-master.md"

echo "Building master markdown..."

# Front matter
cat > "$MASTER" << 'FRONTMATTER'
---
title: "VMO2 Hub — CNF Deployment Platform"
subtitle: "Technical Handover Document"
date: "April 2026"
document-type: "Technical Reference"
version: "1.0"
classification: "Internal"
---

\newpage

# Document Information

| Field | Value |
|-------|-------|
| **Document Type** | Technical Reference |
| **Audience** | Platform engineers, solutions architects, DevOps engineers, development teams |
| **Scope** | Architecture, data models, deployment automation, API contracts, schemas, roadmap |
| **Not in Scope** | Business process documentation, stakeholder management, project governance |
| **Status** | Near-final — under active review |

This is a **technical document** for engineers building and operating the VMO2 Hub CNF deployment platform. It covers system architecture, data models, deployment automation, API contracts, and implementation specifications. For the working reference implementation (Helm charts, orchestrator scripts, lab setup), see the [tech stack repository](https://gitlab.o2virginmedia.com/iced/app-onboarding-v2/app-onboarding-tech-stack).

## How to Read This Document

| If You Need To... | Read... |
|-------------------|---------|
| Understand the system | Part 1: Chapters 1-4 |
| Understand the data model and value resolution | Part 2: Chapters 5-5a |
| Build the deployment orchestrator | Part 3: Chapters 6, 6a, 6b |
| Build the API layer | Part 4: Chapter 7 |
| Understand standards alignment | Part 4: Chapter 8 |
| Plan next steps | Part 5: Chapter 9 |

## Reference Repositories

| Repository | Contents |
|-----------|----------|
| **Tech Stack** — [GitLab](https://gitlab.o2virginmedia.com/iced/app-onboarding-v2/app-onboarding-tech-stack) | Reference implementation: Helm charts, orchestrator (deploy.sh, usecase.sh, FastAPI), deployment payloads, lab setup (Kind + ArgoCD + Nexus + Gitea) |
| **Schemas & Templates** — [GitHub](https://github.com/nijdarshan/argocd-automation) | This document's source, JSON schemas (app-config + API response), IMS config template, CIQ blueprint, support functions guide |

\newpage

FRONTMATTER

# Concatenate all docs with Part headers and page breaks
add_part() {
    echo "" >> "$MASTER"
    echo "\\newpage" >> "$MASTER"
    echo "" >> "$MASTER"
    echo "# Part $1: $2" >> "$MASTER"
    echo "" >> "$MASTER"
}

add_chapter() {
    local file="$DOCS_DIR/$1"
    echo "" >> "$MASTER"
    echo "\\newpage" >> "$MASTER"
    echo "" >> "$MASTER"
    # Bump all headings by one level (# -> ##, ## -> ###, etc.)
    sed 's/^######/#######/; s/^#####/######/; s/^####/#####/; s/^###/####/; s/^##/###/; s/^#/##/' "$file" >> "$MASTER"
    echo "" >> "$MASTER"
}

# Part 1: Platform Overview
add_part "1" "Platform Overview"
add_chapter "01-architecture-overview.md"
add_chapter "02-vendor-onboarding.md"
add_chapter "03-artifact-intake.md"
add_chapter "04-network-design-ip.md"

# Part 2: Data Model & Resolution
add_part "2" "Data Model & Resolution"
add_chapter "05-data-models-templates.md"
add_chapter "05a-values-resolution-pipeline.md"

# Part 3: Deployment Operations
add_part "3" "Deployment Operations"
add_chapter "06-deployment-rollback.md"
add_chapter "06a-deployment-commands-reference.md"
add_chapter "06b-developer-requirements.md"

# Part 4: API & Standards
add_part "4" "API & Standards"
add_chapter "07-api-reference.md"
add_chapter "08-standards-alignment.md"

# Part 5: Roadmap
add_part "5" "Roadmap"
add_chapter "09-future-roadmap.md"

echo "Converting to docx..."

pandoc "$MASTER" \
    -f markdown \
    -t docx \
    --toc \
    --toc-depth=3 \
    --number-sections \
    -o "$OUT_DIR/VMO2_Hub_Handover.docx"

echo "Done: $OUT_DIR/VMO2_Hub_Handover.docx"
rm "$MASTER"
