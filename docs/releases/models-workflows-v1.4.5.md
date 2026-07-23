# KI-Stack Models / Workflows 1.4.5

This security patch keeps models external. Seven manual contracts now distinguish an informational publisher page from an installable payload source; the importer never downloads those files and trusts only filename, size and SHA256. Pony remains the sole automatic external model through fixed Civitai model version 290640 with mandatory integrity verification.

The release also pins CI actions to full commit SHAs and adds Gitleaks, PSScriptAnalyzer, Bandit, CodeQL and model-source-contract checks.
