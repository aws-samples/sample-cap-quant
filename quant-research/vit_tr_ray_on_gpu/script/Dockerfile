ARG REGION

# Base image: PyTorch training image for NeuronX
# FROM public.ecr.aws/neuron/pytorch-training-neuronx:2.6.0-neuronx-py310-sdk2.23.0-ubuntu22.04
FROM public.ecr.aws/deep-learning-containers/tensorflow-training:2.18.0-gpu-py310-cu125-ubuntu22.04-ec2-v1.25


# RUN pip install -U "tensorboard" "timm"
RUN python3 -m pip install scikit-learn
RUN python3 -m pip install matplotlib
RUN pip3 install torch torchvision
RUN pip3 install filelock
RUN pip3 install urllib3==1.26.6
RUN pip3 install tqdm

# Install Ray for distributed computing
RUN pip3 install ray[default]==2.22.0 aiohttp \
    && rm -rf /root/.cache

# Install additional Python dependencies
RUN pip3 install wget awscli regex boto3 pyarrow transformers==4.31.0 tensorboard datasets \
    && rm -rf /root/.cache/


# Copy the main Python script to the working directory for Ray to find it
# COPY ./cnn_training/setup_gpu.sh /cnn_training/
# COPY ./cnn_training/test1_gpu_enhanced.py /cnn_training/
# COPY ./cnn_training/customize.py /cnn_training/
COPY ./cnn_training/ray_ddp.py /cnn_training/



# Make shell scripts executable
# RUN chmod +x /cnn_training/setup_gpu.sh 
RUN chmod +x /cnn_training/ray_ddp.py 


# Set the working directory to scripts
WORKDIR /cnn_training
