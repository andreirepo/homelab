WORKDIR /app

RUN pip install --no-cache-dir docker requests

COPY monitor.py .

CMD ["python", "-u", "monitor.py"]
