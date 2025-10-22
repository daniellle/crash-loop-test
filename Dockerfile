FROM python:3.10-slim

WORKDIR /app

# Install Flask
RUN pip install flask gunicorn

COPY app.py .

# Use gunicorn like your actual app
CMD ["python", "app.py"]
