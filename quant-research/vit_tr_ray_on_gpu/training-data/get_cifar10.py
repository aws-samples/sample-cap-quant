# Load env vars in notebooks.
# from dotenv import load_dotenv
# sload_dotenv()
import os

# import ray.train
# from ray.train import RunConfig, ScalingConfig
# from ray.train.torch import TorchTrainer
import torch
from filelock import FileLock
from torch import nn
from torch.utils.data import DataLoader
from torchvision import datasets, transforms
from torchvision.transforms import Normalize, ToTensor
from torchvision.models import VisionTransformer
from tqdm import tqdm
from typing import Dict, List

import tempfile
import uuid
from typing import Dict, List

def get_dataloaders(batch_size):
    # Transform to normalize the input images.
    transform = transforms.Compose([ToTensor(), Normalize((0.5, 0.5, 0.5), (0.5, 0.5, 0.5))])

    with FileLock(os.path.expanduser("~/data.lock")):
        # Download training data from open datasets.
        training_data = datasets.CIFAR10(
            root="~/data/",
            train=True,
            download=True,
            transform=transform,
        )

        # Download test data from open datasets.
        testing_data = datasets.CIFAR10(
            root="~/data/",
            train=False,
            download=True,
            transform=transform,
        )
    # Create data loaders.
    train_dataloader = DataLoader(training_data, batch_size=batch_size, shuffle=True)
    test_dataloader = DataLoader(testing_data, batch_size=batch_size)

    return train_dataloader, test_dataloader

if __name__ == "__main__":
    train_loader, test_loader = get_dataloaders(batch_size=256)
    print(f"Training samples: {len(train_loader.dataset)}")
    print(f"Test samples: {len(test_loader.dataset)}")

