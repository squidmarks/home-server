FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir prometheus-client==0.21.1 pymongo==4.10.1
COPY exporter.py .
USER 65534:65534
EXPOSE 9500
CMD ["python", "-u", "exporter.py"]
