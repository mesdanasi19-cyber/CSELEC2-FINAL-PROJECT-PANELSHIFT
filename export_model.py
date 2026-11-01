from ultralytics import YOLO

def export():
    # Load your trained weights
    model = YOLO("runs/detect/train/weights/best.pt")

    # Export to ONNX format
    success = model.export(format="onnx", imgsz=640, simplify=True)
    print(f"Export successful: {success}")

if __name__ == '__main__':
    export()