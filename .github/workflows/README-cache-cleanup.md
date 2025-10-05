# Cache Cleanup Workflow

This workflow automatically deletes GitHub Actions caches that are larger than a specified threshold (default: 1MB).

## Features

- **Scheduled execution**: Runs daily at 2 AM UTC
- **Manual execution**: Can be triggered manually with custom parameters
- **Configurable threshold**: Set size threshold in MB (default: 1MB)
- **Dry run mode**: List caches without deleting them
- **Detailed logging**: Shows cache IDs, keys, sizes, and creation dates
- **Error handling**: Continues processing even if individual cache deletions fail

## Usage

### Automatic Execution
The workflow runs automatically every day at 2 AM UTC to clean up large caches.

### Manual Execution
You can manually trigger the workflow from the GitHub Actions tab:

1. Go to Actions → Cleanup Large Caches
2. Click "Run workflow"
3. Optionally configure:
   - **Size threshold**: Size in MB (default: 1)
   - **Dry run**: Enable to list caches without deleting (default: false)

### Parameters

- `size_threshold_mb`: Size threshold in MB. Caches larger than this will be deleted (default: 1)
- `dry_run`: When enabled, lists caches that would be deleted without actually deleting them (default: false)

## Example Outputs

### Dry Run Mode
```
🧹 Starting cache cleanup process
Repository: f3liz-dev/noraneko-runtime
Size threshold: 1 MB (1048576 bytes)
Dry run mode: true

📋 Fetching all caches...
Found 15 total caches

🔍 Analyzing cache sizes...
Found 8 caches larger than 1 MB:

ID: 12345, Key: sccache-linux-x86_64-1234567890, Size: 125.50 MB, Created: 2024-01-15T10:30:00Z
ID: 12346, Key: sccache-windows-x86_64-0987654321, Size: 89.25 MB, Created: 2024-01-14T08:15:00Z

🧪 Dry run mode - no caches will be deleted
Would delete 8 caches totaling 847.32 MB
```

### Actual Deletion
```
🧹 Starting cache cleanup process
Repository: f3liz-dev/noraneko-runtime
Size threshold: 1 MB (1048576 bytes)
Dry run mode: false

📋 Fetching all caches...
Found 15 total caches

🔍 Analyzing cache sizes...
Found 8 caches larger than 1 MB:

🗑️  Deleting 8 large caches...
Deleting cache ID: 12345
✅ Successfully deleted cache 12345
Deleting cache ID: 12346
✅ Successfully deleted cache 12346

🎉 Cache cleanup completed!
Successfully deleted: 8 caches
```

## Why 1MB Threshold?

The default 1MB threshold is intentionally conservative to avoid deleting useful caches while still removing large ones that may be consuming significant storage. Common scenarios:

- **Small caches** (< 1MB): Usually contain configuration files, small dependencies, or metadata
- **Large caches** (> 1MB): Often contain compiled artifacts, large dependencies, or build outputs

You can adjust the threshold based on your needs:
- **Aggressive cleanup**: Use 0.1MB to remove almost all caches
- **Conservative cleanup**: Use 10MB or higher to only remove very large caches

## Permissions

The workflow requires the following permissions:
- `actions: write` - To delete caches
- `contents: read` - To access repository content

## API Rate Limits

The workflow uses the GitHub REST API and is subject to rate limits:
- 5,000 requests per hour for authenticated requests
- The workflow handles pagination automatically
- Large repositories with many caches may take longer to process

## Troubleshooting

### Common Issues

1. **Permission denied**: Ensure the workflow has `actions: write` permission
2. **Rate limit exceeded**: The workflow will fail if it hits API rate limits
3. **Token issues**: The workflow uses `GITHUB_TOKEN` which should be automatically available

### Debugging

Enable dry run mode to see what caches would be deleted without actually deleting them:
```yaml
dry_run: true
```

This helps verify the workflow is working correctly before performing actual deletions.