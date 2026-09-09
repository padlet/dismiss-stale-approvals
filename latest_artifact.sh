#!/bin/bash
# Adapted from: https://gist.github.com/Willsr71/e4884be88f98b4c298692975c0ec8edb


github_token=$1
# NOTE: repository is the full name, e.g. owner/repo
repository=$2
pr_number=$3
branch_name=$4
run_id=$5
artifact_name=$6

echoerr() { echo "$@" 1>&2; }

max_pages=5

current_run_url="https://api.github.com/repos/${repository}/actions/runs/${run_id}"
current_run=$(curl -sS -H "Authorization: Bearer ${github_token}" "${current_run_url}")

latest_workflow_id=$(jq '.workflow_id' <<< "${current_run}" || echo "ERROR")

if [ "${latest_workflow_id}" = "ERROR" ] || [ "${latest_workflow_id}" = "null" ]; then
	echoerr 'Failed to parse GitHub response with jq:'
	echoerr "(url: ${current_run_url})"
	echoerr "${current_run}"
	exit 0
fi
echoerr "Latest workflow ID: ${latest_workflow_id}"

workflow_runs_url="https://api.github.com/repos/${repository}/actions/workflows/${latest_workflow_id}/runs?status=success&branch=${branch_name}"

runs_page=1
runs_count=0
all_workflow_runs='[]'

while true; do
  workflow_runs=$(curl -sS -H "Authorization: Bearer ${github_token}" "${workflow_runs_url}&per_page=100&page=${runs_page}")

  current_runs_count=$(jq '.workflow_runs | if type == "array" then length else 0 end' <<< "${workflow_runs}")
  if [ "${current_runs_count}" -eq 0 ]; then
    break
  fi

  all_workflow_runs=$(jq -s '.[0] + .[1].workflow_runs' <<< "${all_workflow_runs} ${workflow_runs}")
  total_count=$(jq '.total_count // 0' <<< "${workflow_runs}")

  (( runs_count += current_runs_count ))
  (( ++runs_page ))

  if [ "${runs_count}" -ge "${total_count}" ] || [ "${runs_page}" -gt "${max_pages}" ]; then
    break
  fi
done

latest_workflow_run_id=$(jq \
		--argjson pr_number "${pr_number}" \
		'([.[] | select(.pull_requests | any(.number == $pr_number))] | max_by(.run_number)) | .id' <<< ${all_workflow_runs} || echo "ERROR")

if [ "${latest_workflow_run_id}" = "ERROR" ]; then
	echoerr 'Failed to parse GitHub response with jq:'
	echoerr "(url: ${workflow_runs_url})"
	echoerr "${workflow_runs}"
	exit 0
fi

if [ "${latest_workflow_run_id}" = "null" ]; then
  echoerr "No successful workflow run found for PR ${pr_number} on branch ${branch_name}"
  exit 0
fi
echoerr "Latest workflow run ID: ${latest_workflow_run_id}"

artifacts_url="https://api.github.com/repos/${repository}/actions/runs/${latest_workflow_run_id}/artifacts"
artifacts=$(curl -sS -H "Authorization: Bearer ${github_token}" "${artifacts_url}?per_page=100")
latest_artifact_id=$(echo ${artifacts} \
	| jq \
		--arg artifact_name "$artifact_name" \
		'.artifacts[] | select(.name==$artifact_name).id' || echo "ERROR")

if [ "${latest_artifact_id}" = "ERROR" ]; then
	echoerr 'Failed to parse GitHub response with jq:'
	echoerr "(url: ${artifacts_url})"
	echoerr "${artifacts}"
	exit 0
fi

if [ "${latest_artifact_id}" = "null" ]; then
  echoerr "No artifacts found for workflow run ${latest_workflow_run_id}"
  exit 0
fi
echoerr "Latest artifact ID: ${latest_artifact_id}"

curl -sSL -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${github_token}" \
    -o ${artifact_name}.zip https://api.github.com/repos/${repository}/actions/artifacts/${latest_artifact_id}/zip

unzip -q ${artifact_name}.zip

