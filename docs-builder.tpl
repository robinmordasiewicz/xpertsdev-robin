name: "docs-builder"

on:
  repository_dispatch:
    types: [docs]
  workflow_dispatch:
  push:
    paths:
      - "Dockerfile"
      - "docs.conf"
      - "docs/**"
      - "mkdocs.yml"
    branches:
      - "main"

permissions:
  id-token: write
  contents: write
  pull-requests: write

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  terraform:
    name: Job Init
    runs-on: ubuntu-latest
    outputs:
      action: ${{ steps.terraform.outputs.action }}
    steps:
      - id: terraform
        name: ${{ github.ref_name }} deployed is ${{ vars.DEPLOYED }}
        shell: bash
        run: |
          env
          if [[ -n "${{ vars.DEPLOYED }}" ]]
          then
            if [[ "${{ vars.DEPLOYED }}" == "true" ]]
            then
              echo 'action=apply' >> "${GITHUB_OUTPUT}"
            else
              echo 'action=destroy' >> "${GITHUB_OUTPUT}"
            fi
          else
            echo 'action=skip' >> "${GITHUB_OUTPUT}"
          fi

  apply:
    name: Terraform Apply
    if: needs.terraform.outputs.action == 'apply'
    runs-on: ubuntu-latest
    needs: [terraform]
    env:
      image_version: ${{ needs.plan.outputs.image_version }}
    steps:
      - name: Github repository checkout
        uses: actions/checkout@eef61447b9ff4aafe5dcd4e0bbf5d482be7e7871

      - name: Install mkdocs
        run: |
          pip install --upgrade pip
          pip install -U -r requirements.txt

      - name: setup ssh config
        shell: bash
        run: |
          mkdir -p ~/.ssh
          cat << EOF > ~/.ssh/config
          Host xxx
            HostName github.com
            User git
            IdentityFile ~/.ssh/id_ed25519
            StrictHostKeyChecking no
          EOF

      %%INSERTCLONEREPO%%

      - name: Build MkDocs site
        run: |
          docker run --rm -it -v ${{ github.workspace }}:/docs ghcr.io/amerintlxperts/mkdocs:latest build -c -d site/

      - name: Create htaccess password
        run: |
          htpasswd -b -c .htpasswd ${{ secrets.PROJECTNAME }} ${{ secrets.HTPASSWD }}
  
      - name: Microsoft Azure Authentication
        uses: azure/login@a65d910e8af852a8061c627c456678983e180302
        with:
          allow-no-subscriptions: true
          creds: ${{ secrets.AZURE_CREDENTIALS }}
  
      - name: ACR login
        uses: azure/docker-login@15c4aadf093404726ab2ff205b2cdd33fa6d054c
        with:
          login-server: "${{ secrets.ACR_LOGIN_SERVER }}.azurecr.io"
          username: ${{ secrets.ARM_CLIENT_ID }}
          password: ${{ secrets.ARM_CLIENT_SECRET }}
  
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@c47758b77c9736f4b2ef4073d4d51994fabfe349
  
      - name: Build Container  
        run: |
          docker build -t ${{ secrets.ACR_LOGIN_SERVER }}.azurecr.io/docs:${{ env.image_version }} .

      - name: Configure Git
        run: |
          git config --global user.name "github-actions[bot]"
          git config --global user.email "github-actions[bot]@users.noreply.github.com"
     
      - name: Delete Remote Branch if it Exists
        run: |
          git ls-remote --exit-code --heads origin update-version-${{ env.image_version }} && \
          git push origin --delete update-version-${{ env.image_version }} || echo "Branch does not exist"
     
      - name: Update VERSION file
        run: |
          echo "${{ env.image_version }}" > VERSION
          rm -rf docs/theme/
          rm -rf src/
          rm terraform/tfplan
   
      - name: Create Pull Request
        id: create_pr
        uses: peter-evans/create-pull-request@5e914681df9dc83aa4e4905692ca88beb2f9e91f
        with:
          commit-message: "Update VERSION to ${{ env.image_version }}"
          branch: update-version-${{ env.image_version }}
          base: main
          title: "Update VERSION to ${{ env.image_version }}"
          body: "Automatically generated pull request to update the VERSION file to ${{ env.image_version }}."

      - name: Enable Pull Request Automerge
        if: steps.create_pr.outputs.pull-request-operation == 'created'
        uses: peter-evans/enable-pull-request-automerge@v3
        env:
          GH_TOKEN: ${{ secrets.PAT }}
        with:
          token: ${{ secrets.PAT }}
          pull-request-number: ${{ steps.create_pr.outputs.pull-request-number }}
          merge-method: squash
        
  