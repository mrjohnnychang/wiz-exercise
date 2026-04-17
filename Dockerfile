# Use a standard Go base image
FROM golang:1.20-alpine

# Set the working directory inside the container
WORKDIR /app

# Copy the application code into the container
COPY . .

# Download Go modules and build the application
RUN go mod download
RUN go build -o tasky .

# EXERCISE REQUIREMENT: Bake the file directly into the image
RUN echo "Johnny Chang" > /wizexercise.txt

# Expose the port the app runs on (Tasky usually runs on 8080)
EXPOSE 8080

# Start the application
CMD ["./tasky"]
