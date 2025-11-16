import subprocess
import os

def get_terraform_output(output_name, terraform_dir="../../infra"):
    try:
        result = subprocess.run(
            ['terraform', 'output', '-raw', output_name], 
            capture_output=True, 
            text=True, 
            cwd=terraform_dir
        )
        if result.returncode == 0:
            return result.stdout.strip()
        else:
            print(f"Error getting terraform output: {result.stderr}")
            return None
    except Exception as e:
        print(f"Exception: {e}")
        return None

if __name__ == "__main__":
    s3_url = get_terraform_output("ray_cluster_result_s3bucket_url")
    if s3_url:
        print(f"Ray cluster result S3 bucket URL: {s3_url}")
    else:
        print("Failed to get S3 bucket URL")
