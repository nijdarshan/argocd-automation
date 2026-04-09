#!/bin/bash
# Build the Technical Design Document from markdown sources
# Usage: ./build-docx.sh
# Output: VMO2_Application_Onboarding_Technical_Design.docx

set -e
DOCS_DIR="$(cd "$(dirname "$0")/docs" && pwd)"
OUT_DIR="$(cd "$(dirname "$0")" && pwd)"
MASTER="/tmp/vmo2-design-master.md"

echo "Building master markdown..."

# Front matter
cat > "$MASTER" << 'FRONTMATTER'
---
title: "VMO2 Application Onboarding — CNF Deployment Platform"
subtitle: "Technical Design Document"
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

This is a **technical design document** for engineers building and operating the VMO2 Application Onboarding platform. It covers system architecture, data models, deployment automation, API contracts, and implementation specifications. For the working reference implementation (Helm charts, orchestrator scripts, lab setup), see the [tech stack repository](https://gitlab.o2virginmedia.com/iced/app-onboarding-v2/app-onboarding-tech-stack).

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
| **Tech Stack** — [GitLab](https://gitlab.o2virginmedia.com/iced/app-onboarding-v2/app-onboarding-tech-stack) | Reference implementation: Helm charts, orchestrator (deploy.sh, usecase.sh, FastAPI), deployment payloads, lab setup (Kind + ArgoCD + Nexus + Gitea), JSON schemas, IMS config template, CIQ blueprint, support functions guide |

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
    # Bump headings, strip nav links, clean file paths for docx
    awk '
      /^\*Previous:/ { next }
      /^> \*\*Source docs:\*\*/ { next }
      /^> \*\*Key files:\*\*/ { next }
      /^> \*\*Visual reference:\*\*/ { next }
      /^#{1,6} / { sub(/^#/, "##"); print; next }
      {
        # Convert [text](file.md) links to plain text
        gsub(/\[([^\]]+)\]\([0-9][^\)]*\.md[^\)]*\)/, "\\1")
        gsub(/\[([^\]]+)\]\(0[^\)]*\.md[^\)]*\)/, "\\1")
        # Convert schema/template file references to GitLab links
        gsub(/`api-response-schema\.json`/, "[api-response-schema.json](https://gitlab.o2virginmedia.com/iced/app-onboarding-v2/app-onboarding-tech-stack/-/blob/main/schemas/api-response-schema.json)")
        gsub(/`api-response-example\.json`/, "[api-response-example.json](https://gitlab.o2virginmedia.com/iced/app-onboarding-v2/app-onboarding-tech-stack/-/blob/main/schemas/api-response-example.json)")
        gsub(/`app-config-schema\.json`/, "[app-config-schema.json](https://gitlab.o2virginmedia.com/iced/app-onboarding-v2/app-onboarding-tech-stack/-/blob/main/schemas/app-config-schema.json)")
        gsub(/`ims-config-example\.json`/, "[ims-config-example.json](https://gitlab.o2virginmedia.com/iced/app-onboarding-v2/app-onboarding-tech-stack/-/blob/main/templates/ims-config-example.json)")
        gsub(/`ciq_blueprint\.json`/, "[ciq_blueprint.json](https://gitlab.o2virginmedia.com/iced/app-onboarding-v2/app-onboarding-tech-stack/-/blob/main/templates/ciq_blueprint.json)")
        # Strip stale docs/ and template/ paths
        gsub(/`docs\/[^`]*`/, "")
        gsub(/`template\/[^`]*`/, "")
        gsub(/See `docs\/[^`]*`[^.]*\./, "")
        gsub(/`presentation\/[^`]*`/, "the interactive presentation")
        print
      }
    ' "$file" >> "$MASTER"
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

# Appendix: Support Functions Guide
echo "" >> "$MASTER"
echo "\\newpage" >> "$MASTER"
echo "" >> "$MASTER"
echo "# Appendix A: Support Functions Reference" >> "$MASTER"
echo "" >> "$MASTER"
SUPPORT_FUNCS="$OUT_DIR/templates/support-functions-guide.md"
if [ -f "$SUPPORT_FUNCS" ]; then
    awk '/^#{1,6} / { sub(/^#/, "##"); print; next } { print }' "$SUPPORT_FUNCS" >> "$MASTER"
fi

echo "Converting to docx..."

DOCX_NAME="VMO2_Application_Onboarding_Technical_Design.docx"
TEMPLATE="$OUT_DIR/reference.docx"

if [ -f "$TEMPLATE" ]; then
    echo "Using styled template: $TEMPLATE"
    pandoc "$MASTER" \
        -f markdown \
        -t docx \
        --reference-doc="$TEMPLATE" \
        --toc \
        --toc-depth=3 \
        -o "$OUT_DIR/$DOCX_NAME"
else
    echo "No template found, using pandoc defaults"
    pandoc "$MASTER" \
        -f markdown \
        -t docx \
        --toc \
        --toc-depth=3 \
        -o "$OUT_DIR/$DOCX_NAME"
fi

echo "Done: $OUT_DIR/$DOCX_NAME"
rm "$MASTER"
