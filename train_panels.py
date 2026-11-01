from ultralytics import YOLO

def main():
    # Load a pretrained YOLOv8 nano model (fastest for mobile/edge optimization)
    model = YOLO("yolov8n.pt")

    # Train the model on your extracted dataset configuration
    results = model.train(
        data="dataset/data.yaml",
        epochs=50,          # Adjust epochs based on dataset size
        imgsz=640,          # Standard resolution for YOLO
        batch=16,
        device="cpu"        # Change to 0 if you have a local NVIDIA GPU
    )

    print("Training complete! Best weights saved to runs/detect/train/weights/best.pt")

if __name__ == '__main__':
    main()